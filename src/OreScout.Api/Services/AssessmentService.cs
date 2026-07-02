using Npgsql;
using OreScout.Api.Models;

namespace OreScout.Api.Services;

public interface IAssessmentService
{
    Task<AssessmentResponse> AssessAsync(double lat, double lng, CancellationToken ct);
}

/// <summary>
/// The /assessment engine (PROJECT_PLAN.md §5.2 / §6.4). Implements the contract end-to-end:
///   Stage 0  in-region gate -> OUT_OF_REGION
///   Stage 1  read the baked `verdict` from tiles.legality_polygons (most-restrictive overlap)
///   Stage 2  live claims overlay
/// Stages 1 and 2 are data/integration dependent: until the ETL builds legality_polygons and the
/// live MLRS client lands, those resolve to honest `dataGaps` rather than fabricated verdicts.
/// </summary>
public class AssessmentService(NpgsqlDataSource db, IClaimsService claims) : IAssessmentService
{
    private static int Rank(string v) => v switch { "RED" => 3, "YELLOW" => 2, "GREEN" => 1, _ => 0 };

    public async Task<AssessmentResponse> AssessAsync(double lat, double lng, CancellationToken ct)
    {
        await using var conn = await db.OpenConnectionAsync(ct);
        var now = DateTimeOffset.UtcNow;
        var dataGaps = new List<string>();

        // ---- Stage 0: in-region gate ---------------------------------------
        if (!await InRegionAsync(conn, lat, lng, ct))
        {
            return Base(now) with
            {
                CollectingStatus = "OUT_OF_REGION",
                CollectingStatusReason =
                    "Outside the supported region (NV, CA, AZ, CO, UT, NM, OR, ID).",
            };
        }

        var dataVintage = await ScalarAsync(conn,
            "SELECT value FROM public.meta WHERE key = 'padus_version'", ct);

        // ---- Stage 1: baked base verdict from the unified legality layer ----
        bool legalityReady = await ScalarAsync(conn,
            "SELECT to_regclass('tiles.legality_polygons')::text", ct) is not null;

        string status, reason;
        string? ambiguity = null, landManager = null, unitName = null, protection = null;

        if (!legalityReady)
        {
            // ETL has not built the layer yet (§6.6.1.1). Be honest, don't fabricate.
            dataGaps.Add("Legality layer not yet ingested — Phase-1 ETL pending (§6.6.1.1). " +
                         "Land-status verdict is provisional.");
            (status, ambiguity, reason) = NoData();
        }
        else
        {
            var row = await QueryMostRestrictiveAsync(conn, lat, lng, ct);
            if (row is null)
            {
                (status, ambiguity, reason) = NoData();
            }
            else
            {
                status = row.Verdict;
                reason = row.Reason ?? row.Verdict;
                landManager = row.LandManager;
                unitName = row.UnitName;
                protection = row.ProtectionStatus;
                dataVintage ??= row.DataVintage;
                ambiguity = status == "YELLOW" ? "KNOWN" : null;
            }
        }

        // ---- §6.4 standing warnings (IMP-02) --------------------------------
        // 1) Near a RED boundary: a GPS-holding user within 500 m of (but not inside) a
        //    prohibited unit gets an explicit "verify your exact location" nudge.
        // 2) Stale vintage: land-status data older than ~2 years is flagged on every result.
        // Skip the near-boundary warning when the point is already RED: RED units span many
        // rows, so a per-row "not covered" check can otherwise name the very unit the user is
        // inside (caught by independent verification at Montezuma Easement, CO).
        var warnings = new List<string>();
        if (legalityReady && status != "RED")
        {
            var nearRed = await NearbyRedUnitAsync(conn, lat, lng, ct);
            if (nearRed is not null)
                warnings.Add($"Near boundary of {nearRed} — verify your exact location.");
        }
        var padUsDate = await ScalarAsync(conn,
            "SELECT value FROM public.meta WHERE key = 'padus_date'", ct);
        if (VintageYear(padUsDate) is { } year && now.Year - year >= 2)
            warnings.Add($"Land status data may be outdated ({dataVintage ?? "PAD-US"}, {year}).");

        // ---- Stage 2: live claims overlay (§6.4 Stage 2) -------------------
        // Any not-closed claim (Active OR Pending) within the 100m buffer escalates the
        // verdict UP to YELLOW (never down, never RED). Claim failure -> partial result.
        var claimsResult = await claims.GetClaimsAsync(lat, lng, ct);
        var activeClaims = claimsResult.Claims;
        if (claimsResult.DataGap is not null) dataGaps.Add(claimsResult.DataGap);

        if (activeClaims is { Count: > 0 })
        {
            // A claim only exists on federal mineral estate, so it both escalates an open/GREEN
            // point to YELLOW and resolves a no-data UNKNOWN into a KNOWN (claimed) reason.
            // An existing RED or known-YELLOW base keeps its verdict/reason; the claim adds a warning.
            if (Rank(status) < Rank("YELLOW") || ambiguity == "UNKNOWN")
            {
                status = "YELLOW";
                ambiguity = "KNOWN";
                reason = "Recorded mining claim(s) within 100m — verify before prospecting.";
            }
            warnings.Add(ClaimWarning(activeClaims));
        }

        return new AssessmentResponse
        {
            CollectingStatus = status,
            AmbiguityType = ambiguity,
            CollectingStatusReason = reason,
            LandManager = landManager,
            UnitName = unitName,
            ProtectionStatus = protection,
            ActiveClaims = activeClaims,
            Warnings = warnings,
            CannotModel = [.. AssessmentText.CannotModel],
            DataGaps = dataGaps,
            DataVintage = dataVintage ?? "not yet ingested (Phase-1 ETL pending)",
            Disclaimer = AssessmentText.Disclaimer,
            AssessmentDate = now,
        };
    }

    private static string ClaimWarning(List<ActiveClaim> claims)
    {
        // Break down by the real CSE_DISP values (Active / Pending / Filed / ...) rather than
        // assuming a fixed vocabulary.
        var byStatus = claims
            .GroupBy(c => string.IsNullOrWhiteSpace(c.Status) ? "unknown" : c.Status!.ToLowerInvariant())
            .OrderByDescending(g => g.Count())
            .Select(g => $"{g.Count()} {g.Key}");
        return $"Mining claim(s) within 100m: {claims.Count} ({string.Join(", ", byStatus)}). " +
               "A claimant holds mineral rights; verify before prospecting. " +
               "Casual hand-tool collecting may still be allowed.";
    }

    private static (string status, string? ambiguity, string reason) NoData() =>
        ("YELLOW", "UNKNOWN",
         "No land-management data here — treat as possibly private; verify ownership before entering.");

    private AssessmentResponse Base(DateTimeOffset now) => new()
    {
        CollectingStatus = "YELLOW",
        CollectingStatusReason = "",
        Warnings = [],
        CannotModel = [.. AssessmentText.CannotModel],
        DataGaps = [],
        Disclaimer = AssessmentText.Disclaimer,
        AssessmentDate = now,
    };

    private static async Task<bool> InRegionAsync(NpgsqlConnection conn, double lat, double lng, CancellationToken ct)
    {
        await using var cmd = new NpgsqlCommand("SELECT orescout_in_region(@lat, @lng)", conn);
        cmd.Parameters.AddWithValue("lat", lat);
        cmd.Parameters.AddWithValue("lng", lng);
        return (bool)(await cmd.ExecuteScalarAsync(ct))!;
    }

    private static async Task<string?> ScalarAsync(NpgsqlConnection conn, string sql, CancellationToken ct)
    {
        await using var cmd = new NpgsqlCommand(sql, conn);
        var result = await cmd.ExecuteScalarAsync(ct);
        return result is null or DBNull ? null : result.ToString();
    }

    private async Task<LegalityRow?> QueryMostRestrictiveAsync(
        NpgsqlConnection conn, double lat, double lng, CancellationToken ct)
    {
        // ST_Covers (not ST_Contains): a point exactly ON a polygon's boundary must still
        // match it, so a point on a Wilderness/WSA edge resolves most-restrictive (RED)
        // instead of falling through to the surrounding open polygon (§6.4, IMP-02).
        const string sql = """
            SELECT verdict, reason, land_manager, unit_nm, protection_status, data_vintage
            FROM tiles.legality_polygons
            WHERE ST_Covers(geom, ST_SetSRID(ST_MakePoint(@lng, @lat), 4326))
            ORDER BY orescout_rank(verdict) DESC
            LIMIT 1
            """;
        await using var cmd = new NpgsqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("lat", lat);
        cmd.Parameters.AddWithValue("lng", lng);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        if (!await r.ReadAsync(ct)) return null;
        return new LegalityRow(
            r.GetString(0),
            r.IsDBNull(1) ? null : r.GetString(1),
            r.IsDBNull(2) ? null : r.GetString(2),
            r.IsDBNull(3) ? null : r.GetString(3),
            r.IsDBNull(4) ? null : r.GetString(4),
            r.IsDBNull(5) ? null : r.GetString(5));
    }

    /// <summary>
    /// Nearest RED unit within 500 m that does NOT cover the point itself (§6.4 warning,
    /// IMP-02). A point already inside RED is RED — the warning is for open/ambiguous
    /// ground near the line. The bbox && filter keeps the GIST index in play; the
    /// geography cast makes 500 m correct at any latitude.
    /// </summary>
    private static async Task<string?> NearbyRedUnitAsync(
        NpgsqlConnection conn, double lat, double lng, CancellationToken ct)
    {
        const string sql = """
            WITH pt AS (SELECT ST_SetSRID(ST_MakePoint(@lng, @lat), 4326) AS g)
            SELECT COALESCE(unit_nm, reason, 'a protected area')
            FROM tiles.legality_polygons, pt
            WHERE verdict = 'RED'
              AND geom && ST_Expand(pt.g, 0.01)
              AND NOT ST_Covers(geom, pt.g)
              AND ST_DWithin(geom::geography, pt.g::geography, 500)
            ORDER BY ST_Distance(geom::geography, pt.g::geography)
            LIMIT 1
            """;
        await using var cmd = new NpgsqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("lat", lat);
        cmd.Parameters.AddWithValue("lng", lng);
        var result = await cmd.ExecuteScalarAsync(ct);
        return result is null or DBNull ? null : (string)result;
    }

    /// <summary>
    /// First 4-digit year in the meta padus_date value (e.g. "2024 (ScienceBase State GDB)").
    /// Null when absent/unparseable — the staleness warning is then skipped, never thrown.
    /// </summary>
    private static int? VintageYear(string? padUsDate)
    {
        if (padUsDate is null) return null;
        var m = System.Text.RegularExpressions.Regex.Match(padUsDate, @"\b(19|20)\d{2}\b");
        return m.Success ? int.Parse(m.Value) : null;
    }

    private record LegalityRow(
        string Verdict, string? Reason, string? LandManager,
        string? UnitName, string? ProtectionStatus, string? DataVintage);
}
