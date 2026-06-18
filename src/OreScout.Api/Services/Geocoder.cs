using System.Globalization;
using System.Text.Json;
using OreScout.Api.Models;

namespace OreScout.Api.Services;

public interface IGeocoder
{
    Task<GeocodeResponse> SearchAsync(string query, CancellationToken ct);
}

/// <summary>
/// Proxies Nominatim/OSM (PROJECT_PLAN.md §6.2). Keeps the geocoder choice internal
/// and lets us add caching / swap providers later without touching clients. Sends a
/// descriptive User-Agent and honors the ≤1 req/s policy (the typed HttpClient is the
/// single egress point; throttling/caching can be layered here).
/// </summary>
public class NominatimGeocoder(HttpClient http, ILogger<NominatimGeocoder> log) : IGeocoder
{
    public async Task<GeocodeResponse> SearchAsync(string query, CancellationToken ct)
    {
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

    private static bool TryGetDouble(JsonElement el, string prop, out double value)
    {
        value = 0;
        // Nominatim returns lat/lon as strings.
        return el.TryGetProperty(prop, out var p)
            && double.TryParse(p.GetString(), NumberStyles.Float, CultureInfo.InvariantCulture, out value);
    }
}
