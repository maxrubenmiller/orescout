using System.Globalization;
using System.Text.Json;
using Microsoft.Extensions.Caching.Memory;
using OreScout.Api.Models;

namespace OreScout.Api.Services;

/// <summary>Result of the live claims check. Claims=null signals "not checked" (with a DataGap).</summary>
public record ClaimsResult(List<ActiveClaim>? Claims, string? DataGap);

public interface IClaimsService
{
    Task<ClaimsResult> GetClaimsAsync(double lat, double lng, CancellationToken ct);
}

/// <summary>
/// Live anti-claim-jumping check against BLM MLRS (docs/planning/PROJECT_PLAN.md §5.1 / §6.4 Stage 2).
/// Queries the "Not Closed" claims layer with a 100m buffer around the point (raw point-
/// intersect misses gaps between PLSS aliquots). On any failure/timeout it returns
/// (null, dataGap) so the assessment degrades to a partial result rather than failing (§6.3).
/// Successful results are cached 1h keyed on the coord rounded to 3 decimals (~110m, matching
/// the buffer) to shield BLM from repeated identical clicks (§6.10); failures are NEVER cached,
/// so recovery is immediate.
/// </summary>
public class MlrsClaimsService(
    HttpClient http, IMemoryCache cache, IConfiguration cfg, ILogger<MlrsClaimsService> log) : IClaimsService
{
    private static readonly TimeSpan CacheTtl = TimeSpan.FromHours(1);

    private const string FailGap =
        "Mining claims data temporarily unavailable. Verify active claims at reports.blm.gov before prospecting.";

    public async Task<ClaimsResult> GetClaimsAsync(double lat, double lng, CancellationToken ct)
    {
        var inv = CultureInfo.InvariantCulture;
        var cacheKey = string.Create(inv, $"claims:{Math.Round(lat, 3)}:{Math.Round(lng, 3)}");
        if (cache.TryGetValue(cacheKey, out ClaimsResult? cached) && cached is not null)
        {
            log.LogDebug("MLRS cache hit for {Lat},{Lng}", lat, lng);
            return cached;
        }

        var queryUrl = cfg["Mlrs:QueryUrl"]!;
        var caseUrlTpl = cfg["Mlrs:CaseDetailUrl"]!;
        var buffer = cfg.GetValue<int?>("Mlrs:BufferMeters") ?? 100;
        var timeout = TimeSpan.FromSeconds(cfg.GetValue<int?>("Mlrs:TimeoutSeconds") ?? 10);

        var geom = $"{{\"x\":{lng.ToString(inv)},\"y\":{lat.ToString(inv)},\"spatialReference\":{{\"wkid\":4326}}}}";
        string Q(string k, string v) => $"{k}={Uri.EscapeDataString(v)}";
        var url = queryUrl + "?" + string.Join("&",
        [
            Q("geometry", geom), Q("geometryType", "esriGeometryPoint"),
            Q("inSR", "4326"), Q("outSR", "4326"),
            Q("distance", buffer.ToString()), Q("units", "esriSRUnit_Meter"),
            Q("spatialRel", "esriSpatialRelIntersects"),
            Q("outFields", "CSE_NR,CSE_NAME,BLM_PROD,CSE_DISP,RCRD_ACRS,Modified"),
            Q("returnGeometry", "false"), Q("f", "json")
        ]);

        try
        {
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(timeout);

            log.LogDebug("MLRS upstream query for {Lat},{Lng}", lat, lng);
            using var resp = await http.GetAsync(url, cts.Token);
            resp.EnsureSuccessStatusCode();
            await using var stream = await resp.Content.ReadAsStreamAsync(cts.Token);
            using var doc = await JsonDocument.ParseAsync(stream, cancellationToken: cts.Token);

            // ArcGIS can return {"error":{...}} with HTTP 200.
            if (doc.RootElement.TryGetProperty("error", out _))
            {
                log.LogWarning("MLRS returned an error payload for {Lat},{Lng}", lat, lng);
                return new ClaimsResult(null, FailGap);
            }

            var claims = new List<ActiveClaim>();
            if (doc.RootElement.TryGetProperty("features", out var feats))
            {
                foreach (var f in feats.EnumerateArray())
                {
                    if (!f.TryGetProperty("attributes", out var a)) continue;
                    var serial = GetStr(a, "CSE_NR");
                    if (serial is null) continue;
                    claims.Add(new ActiveClaim(
                        serial, GetStr(a, "CSE_NAME"), GetStr(a, "BLM_PROD"), GetStr(a, "CSE_DISP"),
                        string.Format(caseUrlTpl, Uri.EscapeDataString(serial))));
                }
            }
            var result = new ClaimsResult(claims, null);
            cache.Set(cacheKey, result, CacheTtl); // successes only — failure paths below skip the cache
            return result;
        }
        catch (Exception ex)
        {
            log.LogWarning(ex, "MLRS claim check failed for {Lat},{Lng}", lat, lng);
            return new ClaimsResult(null, FailGap);
        }
    }

    private static string? GetStr(JsonElement a, string prop) =>
        a.TryGetProperty(prop, out var v) && v.ValueKind != JsonValueKind.Null
            ? (v.ValueKind == JsonValueKind.String ? v.GetString() : v.ToString())
            : null;
}
