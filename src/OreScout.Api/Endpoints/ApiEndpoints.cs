using System.Text;
using System.Text.Json;
using Microsoft.EntityFrameworkCore;
using Npgsql;
using OreScout.Api.Data;
using OreScout.Api.Models;
using OreScout.Api.Services;

namespace OreScout.Api.Endpoints;

public static class ApiEndpoints
{
    private static readonly JsonSerializerOptions Web = new(JsonSerializerDefaults.Web);
    private static readonly string[] ValidStatuses = ["want_to_visit", "visited"];

    public static void MapApiV1(this WebApplication app)
    {
        var v1 = app.MapGroup("/api/v1");
        MapHealth(v1);
        MapMeta(v1);
        MapGeocode(v1);
        MapAssessment(v1);
        MapPins(v1);
    }

    // ---- Health (exempt from API key — §6.2) -------------------------------
    private static void MapHealth(RouteGroupBuilder g) => g.MapGet("/health",
        async (NpgsqlDataSource db, IHttpClientFactory hf, IConfiguration cfg, CancellationToken ct) =>
        {
            string pg = "ok";
            try
            {
                await using var c = await db.OpenConnectionAsync(ct);
                await using var cmd = new NpgsqlCommand("SELECT 1", c);
                await cmd.ExecuteScalarAsync(ct);
            }
            catch { pg = "down"; }

            string tile = "ok";
            try
            {
                var http = hf.CreateClient();
                http.Timeout = TimeSpan.FromSeconds(3);
                var r = await http.GetAsync(cfg["TileServ:CatalogUrl"], ct);
                tile = r.IsSuccessStatusCode ? "ok" : "down";
            }
            catch { tile = "down"; }

            var resp = new HealthResponse(pg == "ok" ? "ok" : "unhealthy", new HealthChecks(pg, tile));
            return pg == "ok" ? Results.Ok(resp) : Results.Json(resp, statusCode: 503);
        });

    // ---- Meta --------------------------------------------------------------
    private static void MapMeta(RouteGroupBuilder g) => g.MapGet("/meta",
        async (NpgsqlDataSource db, IConfiguration cfg, CancellationToken ct) =>
        {
            var m = new Dictionary<string, string?>();
            var sources = new List<DataSourceInfo>();
            await using (var c = await db.OpenConnectionAsync(ct))
            {
                await using (var cmd = new NpgsqlCommand("SELECT key, value FROM public.meta", c))
                await using (var r = await cmd.ExecuteReaderAsync(ct))
                    while (await r.ReadAsync(ct))
                        m[r.GetString(0)] = r.IsDBNull(1) ? null : r.GetString(1);

                // Freshness registry (docs/DATA_REFRESH_PLAN.md). to_regclass guard: a DB that
                // predates the registry gets an empty list, NOT a 500 — while connection-level
                // failures still propagate to the global handler's 503 (§6.3 unchanged).
                await using (var probe = new NpgsqlCommand(
                    "SELECT to_regclass('public.data_sources') IS NOT NULL", c))
                if (await probe.ExecuteScalarAsync(ct) is true)
                {
                    const string sql = """
                        SELECT source_key, role, vintage, refreshed_at, max_age_days, last_gate_status,
                               (max_age_days IS NOT NULL AND refreshed_at IS NOT NULL
                                AND refreshed_at < now() - make_interval(days => max_age_days)) AS stale
                        FROM public.data_sources ORDER BY source_key
                        """;
                    await using var cmd = new NpgsqlCommand(sql, c);
                    await using var r = await cmd.ExecuteReaderAsync(ct);
                    while (await r.ReadAsync(ct))
                        sources.Add(new DataSourceInfo(
                            r.GetString(0),
                            r.IsDBNull(1) ? null : r.GetString(1),
                            r.IsDBNull(2) ? null : r.GetString(2),
                            r.IsDBNull(3) ? null : r.GetFieldValue<DateTimeOffset>(3),
                            r.IsDBNull(4) ? null : r.GetInt32(4),
                            r.IsDBNull(5) ? null : r.GetString(5),
                            r.GetBoolean(6)));
                }
            }

            var states = cfg.GetSection("SupportedStates").Get<string[]>() ?? [];
            return Results.Ok(new MetaResponse(
                m.GetValueOrDefault("padus_version"), m.GetValueOrDefault("padus_date"),
                m.GetValueOrDefault("sma_date"), m.GetValueOrDefault("claims_as_of"), states, sources));
        });

    // ---- Geocode -----------------------------------------------------------
    private static void MapGeocode(RouteGroupBuilder g) => g.MapGet("/geocode",
        async (string? q, IGeocoder geo, CancellationToken ct) =>
        {
            if (string.IsNullOrWhiteSpace(q))
                return Err(400, "bad_request", "Query parameter 'q' is required.");
            try
            {
                return Results.Ok(await geo.SearchAsync(q, ct));
            }
            // Nominatim down or timed out (the HttpClient timeout surfaces as an OCE) is a
            // degraded dependency, not a bug → 503, retryable. Client aborts still propagate.
            catch (Exception ex) when (ex is HttpRequestException
                || (ex is OperationCanceledException && !ct.IsCancellationRequested))
            {
                return Err(503, "geocode_unavailable",
                    "Geocoding is temporarily unavailable. Please try again shortly.");
            }
        });

    // ---- Assessment --------------------------------------------------------
    private static void MapAssessment(RouteGroupBuilder g) => g.MapGet("/assessment",
        async (double lat, double lng, IAssessmentService svc, CancellationToken ct) =>
        {
            if (lat is < -90 or > 90 || lng is < -180 or > 180)
                return Err(400, "invalid_coordinates", "lat must be -90..90 and lng -180..180.");
            return Results.Ok(await svc.AssessAsync(lat, lng, ct));
        });

    // ---- Pins --------------------------------------------------------------
    private static void MapPins(RouteGroupBuilder g)
    {
        g.MapGet("/pins", async (OreScoutDbContext db, CancellationToken ct) =>
            Results.Ok((await db.Pins.OrderByDescending(p => p.CreatedAt).ToListAsync(ct))
                .Select(ToResponse)));

        g.MapGet("/pins/{id:guid}", async (Guid id, OreScoutDbContext db, CancellationToken ct) =>
        {
            var pin = await db.Pins.FindAsync([id], ct);
            return pin is null ? Err(404, "not_found", "Pin not found.") : Results.Ok(ToResponse(pin));
        });

        g.MapPost("/pins", async (CreatePinRequest req, OreScoutDbContext db,
            IAssessmentService svc, CancellationToken ct) =>
        {
            if (req.Lat is < -90 or > 90 || req.Lng is < -180 or > 180)
                return Err(400, "invalid_coordinates", "lat must be -90..90 and lng -180..180.");
            if (ValidateMetadata(req.Title, req.Notes) is { } err)
                return err;
            var status = req.Status ?? "want_to_visit";
            if (!ValidStatuses.Contains(status))
                return Err(400, "bad_request", "status must be 'want_to_visit' or 'visited'.");

            // Server-side snapshot at save time (§6.2 save contract).
            var assessment = await svc.AssessAsync(req.Lat, req.Lng, ct);
            var pin = new Pin
            {
                Lat = req.Lat,
                Lng = req.Lng,
                Title = req.Title.Trim(),
                Notes = req.Notes,
                Status = status,
                Tags = DeriveTags(assessment),
                AssessmentSnapshot = JsonSerializer.Serialize(assessment, Web),
                AssessmentDate = assessment.AssessmentDate,
            };
            db.Pins.Add(pin);
            await db.SaveChangesAsync(ct);
            return Results.Created($"/api/v1/pins/{pin.Id}", ToResponse(pin));
        });

        g.MapPut("/pins/{id:guid}", async (Guid id, UpdatePinRequest req,
            OreScoutDbContext db, CancellationToken ct) =>
        {
            var pin = await db.Pins.FindAsync([id], ct);
            if (pin is null) return Err(404, "not_found", "Pin not found.");
            if (ValidateMetadata(req.Title, req.Notes) is { } err)
                return err;
            if (!ValidStatuses.Contains(req.Status))
                return Err(400, "bad_request", "status must be 'want_to_visit' or 'visited'.");

            // PUT edits metadata only — location + snapshot are immutable (§6.2).
            pin.Title = req.Title.Trim();
            pin.Notes = req.Notes;
            pin.Status = req.Status;
            await db.SaveChangesAsync(ct);
            await db.Entry(pin).ReloadAsync(ct);   // pick up trigger-maintained updated_at
            return Results.Ok(ToResponse(pin));
        });

        g.MapDelete("/pins/{id:guid}", async (Guid id, OreScoutDbContext db, CancellationToken ct) =>
        {
            var pin = await db.Pins.FindAsync([id], ct);
            if (pin is null) return Err(404, "not_found", "Pin not found.");
            db.Pins.Remove(pin);
            await db.SaveChangesAsync(ct);
            return Results.NoContent();
        });

        g.MapGet("/pins/{id:guid}/export", async (Guid id, string? format,
            OreScoutDbContext db, CancellationToken ct) =>
        {
            var pin = await db.Pins.FindAsync([id], ct);
            if (pin is null) return Err(404, "not_found", "Pin not found.");
            format ??= "gpx";
            if (!string.Equals(format, "gpx", StringComparison.OrdinalIgnoreCase))
                return Err(400, "unsupported_format", "Only 'gpx' is supported in the POC (KML deferred — see README).");

            var bytes = Encoding.UTF8.GetBytes(BuildGpx(pin));
            return Results.File(bytes, "application/gpx+xml", $"{SafeFileName(pin.Title)}.gpx");
        });
    }

    // ---- Helpers -----------------------------------------------------------
    private static IResult Err(int status, string code, string message) =>
        Results.Json(new ApiError(new ApiErrorBody(code, message)), statusCode: status);

    /// <summary>
    /// Shared POST/PUT pin metadata checks. Title cap matches the DB varchar(200) column
    /// (a longer title previously escaped as a PostgresException → 500); the notes cap is
    /// app-level sanity only (the column is TEXT). Returns null when valid.
    /// </summary>
    private static IResult? ValidateMetadata(string? title, string? notes)
    {
        if (string.IsNullOrWhiteSpace(title))
            return Err(400, "bad_request", "title is required.");
        if (title.Trim().Length > 200)
            return Err(400, "bad_request", "title must be 200 characters or fewer.");
        if (notes is { Length: > 4000 })
            return Err(400, "bad_request", "notes must be 4000 characters or fewer.");
        return null;
    }

    private static PinResponse ToResponse(Pin p)
    {
        object? snapshot = p.AssessmentSnapshot is null
            ? null
            : JsonSerializer.Deserialize<JsonElement>(p.AssessmentSnapshot, Web);
        return new PinResponse(p.Id, p.Lat, p.Lng, p.Title, p.Notes, p.Status, p.Tags,
            snapshot, p.AssessmentDate, p.CreatedAt, p.UpdatedAt);
    }

    private static string[] DeriveTags(AssessmentResponse a)
    {
        var tags = new List<string>();

        if (a.LandManager is { } m)
            tags.Add(m.ToUpperInvariant() switch
            {
                "BLM" => "BLM",
                "USFS" => "National Forest",
                "ST" => "State Trust Land",
                _ => m
            });

        var legal = (a.CollectingStatus, a.AmbiguityType) switch
        {
            ("RED", _) => "Prohibited",
            ("YELLOW", "UNKNOWN") => "Possibly Private",
            ("YELLOW", _) => "Ambiguous",
            ("GREEN", _) => "Open",
            _ => null
        };
        if (legal is not null) tags.Add(legal);

        if (a.ActiveClaims is { Count: > 0 }) tags.Add("Active Claim Nearby");
        return [.. tags];
    }

    private static string BuildGpx(Pin p)
    {
        var name = System.Security.SecurityElement.Escape(p.Title);
        var desc = System.Security.SecurityElement.Escape(p.Notes ?? "");
        var lat = p.Lat.ToString(System.Globalization.CultureInfo.InvariantCulture);
        var lng = p.Lng.ToString(System.Globalization.CultureInfo.InvariantCulture);
        return $"""
            <?xml version="1.0" encoding="UTF-8"?>
            <gpx version="1.1" creator="OreScout" xmlns="http://www.topografix.com/GPX/1/1">
              <wpt lat="{lat}" lon="{lng}">
                <name>{name}</name>
                <desc>{desc}</desc>
              </wpt>
            </gpx>
            """;
    }

    private static string SafeFileName(string title)
    {
        var cleaned = new string(title.Select(c => char.IsLetterOrDigit(c) ? c : '_').ToArray());
        return string.IsNullOrWhiteSpace(cleaned) ? "pin" : cleaned;
    }
}
