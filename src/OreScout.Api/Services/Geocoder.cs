using System.Globalization;
using System.Text.Json;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Configuration;
using OreScout.Api.Models;

namespace OreScout.Api.Services;

public interface IGeocoder
{
    Task<GeocodeResponse> SearchAsync(string query, CancellationToken ct);
}

/// <summary>
/// Proxies Nominatim/OSM (PROJECT_PLAN.md §6.2). Keeps the geocoder choice internal and lets us
/// swap providers later without touching clients. Sends a descriptive User-Agent and honors the
/// OSM usage policy two ways (§6.10): a 24h in-memory cache keyed on the normalized query (empty
/// result lists are cached too — "no matches" is an answer), and a process-wide gate that spaces
/// upstream calls ≥1s apart, so a burst of distinct queries serializes rather than hammering
/// Nominatim. Upstream failures propagate as HttpRequestException / timeout; the /geocode
/// endpoint maps them to 503 geocode_unavailable.
/// </summary>
public class NominatimGeocoder(HttpClient http, IMemoryCache cache, IConfiguration cfg, ILogger<NominatimGeocoder> log) : IGeocoder
{
    private static readonly TimeSpan CacheTtl = TimeSpan.FromHours(24);
    private static readonly TimeSpan MinUpstreamInterval = TimeSpan.FromSeconds(1);

    // Region gate: keep only results in the app's supported states (§6.2). Driven by the SAME
    // SupportedStates config the assessment in-region gate uses, so adding a state stays a
    // one-line config change (§6.13 invariant) — the geocoder picks it up automatically.
    private readonly HashSet<string> _supported = new(
        cfg.GetSection("SupportedStates").Get<string[]>() ?? [], StringComparer.OrdinalIgnoreCase);

    // Full state name → USPS abbrev, for the addressdetails fallback when ISO 3166-2 is absent.
    private static readonly Dictionary<string, string> StateAbbrevByName = new(StringComparer.OrdinalIgnoreCase)
    {
        ["Nevada"] = "NV", ["California"] = "CA", ["Arizona"] = "AZ", ["Colorado"] = "CO",
        ["Utah"] = "UT", ["New Mexico"] = "NM", ["Oregon"] = "OR", ["Idaho"] = "ID",
    };

    // Coarse bounding box over the 8 supported states (W,N,E,S) used as a Nominatim SEARCH bias
    // (bounded=1). Nominatim ranks its top-N by global importance, so without this a common name
    // ("Bear Creek") returns only Appalachian hits and nothing western survives the state trim.
    // The exact per-state filter below is authoritative; this box only shapes the candidate pool
    // (it bleeds into WY/MT/TX slivers, which the state filter then drops).
    private const string ViewBox = "-124.85,49.05,-102.00,31.30";

    // Typed-HttpClient services are transient, but the ≤1 req/s policy is per PROCESS, so the
    // gate is shared by every instance. _nextUpstreamAllowedUtc is only touched under the gate.
    private static readonly SemaphoreSlim UpstreamGate = new(1, 1);
    private static DateTimeOffset _nextUpstreamAllowedUtc = DateTimeOffset.MinValue;

    public async Task<GeocodeResponse> SearchAsync(string query, CancellationToken ct)
    {
        var key = $"geocode:{Normalize(query)}";
        if (cache.TryGetValue(key, out GeocodeResponse? cached) && cached is not null)
        {
            log.LogDebug("Geocode cache hit for '{Query}'", query);
            return cached;
        }

        var response = await SearchUpstreamAsync(query, ct);
        cache.Set(key, response, CacheTtl); // successes only — failures threw above
        return response;
    }

    private async Task<GeocodeResponse> SearchUpstreamAsync(string query, CancellationToken ct)
    {
        await UpstreamGate.WaitAsync(ct);
        try
        {
            var wait = _nextUpstreamAllowedUtc - DateTimeOffset.UtcNow;
            if (wait > TimeSpan.Zero)
                await Task.Delay(wait, ct);

            log.LogDebug("Nominatim upstream call at {At:HH:mm:ss.fff} for '{Query}'",
                DateTimeOffset.UtcNow, query);

            // Bias the search to the western region (bounded viewbox) so the candidate pool is
            // western, ask for 15 US results WITH address details, then keep only the supported
            // states (a place search should never surface land OreScout can't answer for).
            var url = $"/search?format=jsonv2&addressdetails=1&countrycodes=us&bounded=1&viewbox={ViewBox}&limit=15&q={Uri.EscapeDataString(query)}";
            using var resp = await http.GetAsync(url, ct);
            resp.EnsureSuccessStatusCode();

            await using var stream = await resp.Content.ReadAsStreamAsync(ct);
            using var doc = await JsonDocument.ParseAsync(stream, cancellationToken: ct);

            var results = new List<GeocodeResult>();
            foreach (var el in doc.RootElement.EnumerateArray())
            {
                if (!TryGetDouble(el, "lat", out var lat) || !TryGetDouble(el, "lon", out var lng))
                    continue;
                var state = StateOf(el);
                if (state is null || !_supported.Contains(state))
                    continue; // outside the supported region — not searchable here (§6.2)
                var label = el.TryGetProperty("display_name", out var dn) ? dn.GetString() ?? query : query;
                var type = el.TryGetProperty("type", out var t) ? t.GetString() : null;
                results.Add(new GeocodeResult(label, lat, lng, type));
            }

            log.LogDebug("Geocode '{Query}' -> {Count} results", query, results.Count);
            return new GeocodeResponse(results);
        }
        finally
        {
            _nextUpstreamAllowedUtc = DateTimeOffset.UtcNow + MinUpstreamInterval;
            UpstreamGate.Release();
        }
    }

    /// <summary>Cache key: case- and whitespace-insensitive ("Tonopah  NV" == "tonopah nv").</summary>
    private static string Normalize(string query) =>
        string.Join(' ', query.ToLowerInvariant().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));

    private static bool TryGetDouble(JsonElement el, string prop, out double value)
    {
        value = 0;
        // Nominatim returns lat/lon as strings.
        return el.TryGetProperty(prop, out var p)
            && double.TryParse(p.GetString(), NumberStyles.Float, CultureInfo.InvariantCulture, out value);
    }

    /// <summary>USPS state abbrev for a Nominatim result, or null. Prefers the ISO 3166-2 code
    /// ("US-NV" → "NV"); falls back to the full <c>state</c> name. Requires addressdetails=1.</summary>
    private static string? StateOf(JsonElement el)
    {
        if (!el.TryGetProperty("address", out var addr) || addr.ValueKind != JsonValueKind.Object)
            return null;
        if (addr.TryGetProperty("ISO3166-2-lvl4", out var iso) && iso.GetString() is { } code
            && code.StartsWith("US-", StringComparison.OrdinalIgnoreCase))
            return code[3..].ToUpperInvariant();
        if (addr.TryGetProperty("state", out var s) && s.GetString() is { } name
            && StateAbbrevByName.TryGetValue(name, out var ab))
            return ab;
        return null;
    }
}
