using System.Globalization;
using System.Text.Json;
using Microsoft.Extensions.Caching.Memory;
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
public class NominatimGeocoder(HttpClient http, IMemoryCache cache, ILogger<NominatimGeocoder> log) : IGeocoder
{
    private static readonly TimeSpan CacheTtl = TimeSpan.FromHours(24);
    private static readonly TimeSpan MinUpstreamInterval = TimeSpan.FromSeconds(1);

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

            var url = $"/search?format=jsonv2&limit=5&q={Uri.EscapeDataString(query)}";
            using var resp = await http.GetAsync(url, ct);
            resp.EnsureSuccessStatusCode();

            await using var stream = await resp.Content.ReadAsStreamAsync(ct);
            using var doc = await JsonDocument.ParseAsync(stream, cancellationToken: ct);

            var results = new List<GeocodeResult>();
            foreach (var el in doc.RootElement.EnumerateArray())
            {
                if (!TryGetDouble(el, "lat", out var lat) || !TryGetDouble(el, "lon", out var lng))
                    continue;
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
}
