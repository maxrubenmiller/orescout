using System.Net;
using System.Net.Http.Json;
using System.Text;
using OreScout.Api.Models;
using OreScout.Api.Tests.Infrastructure;

namespace OreScout.Api.Tests;

/// <summary>
/// Bad input must be rejected with a 400 before the assessment engine or the database is touched.
/// </summary>
public class InputValidationTests(ApiFactory factory) : IClassFixture<ApiFactory>
{
    private readonly HttpClient _client = factory.CreateAuthedClient();

    [Theory]
    [InlineData("95", "-117")]      // latitude past the pole
    [InlineData("39.5", "-200")]    // longitude past the antimeridian
    [InlineData("NaN", "-117")]     // NaN compares false to every bound
    [InlineData("39.5", "Infinity")]
    public async Task Assessment_rejects_invalid_coordinates(string lat, string lng)
    {
        var before = factory.Assessment.Calls;

        var res = await _client.GetAsync($"/api/v1/assessment?lat={lat}&lng={lng}");

        Assert.Equal(HttpStatusCode.BadRequest, res.StatusCode);
        Assert.Equal(before, factory.Assessment.Calls);
    }

    [Fact]
    public async Task Create_pin_rejects_out_of_range_coordinates()
    {
        var res = await _client.PostAsJsonAsync("/api/v1/pins",
            new { lat = 95.0, lng = -200.0, title = "Off the map" });

        await AssertBadRequest(res, "invalid_coordinates");
    }

    [Fact]
    public async Task Create_pin_rejects_NaN_coordinates()
    {
        // A NaN pin used to persist and then break GET /pins for every caller.
        var json = """{ "lat": "NaN", "lng": "NaN", "title": "NaN pin" }""";

        var res = await _client.PostAsync("/api/v1/pins",
            new StringContent(json, Encoding.UTF8, "application/json"));

        Assert.Equal(HttpStatusCode.BadRequest, res.StatusCode);
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    public async Task Create_pin_requires_a_title(string title)
    {
        var res = await _client.PostAsJsonAsync("/api/v1/pins", new { lat = 39.5, lng = -117.0, title });

        await AssertBadRequest(res, "bad_request");
    }

    [Fact]
    public async Task Create_pin_caps_title_length()
    {
        var res = await _client.PostAsJsonAsync("/api/v1/pins",
            new { lat = 39.5, lng = -117.0, title = new string('x', 201) });

        await AssertBadRequest(res, "bad_request");
    }

    [Fact]
    public async Task Create_pin_rejects_unknown_status()
    {
        var res = await _client.PostAsJsonAsync("/api/v1/pins",
            new { lat = 39.5, lng = -117.0, title = "Camp", status = "abandoned" });

        await AssertBadRequest(res, "bad_request");
    }

    [Fact]
    public async Task Geocode_requires_a_query()
    {
        var res = await _client.GetAsync("/api/v1/geocode?q=");

        await AssertBadRequest(res, "bad_request");
    }

    private static async Task AssertBadRequest(HttpResponseMessage res, string code)
    {
        Assert.Equal(HttpStatusCode.BadRequest, res.StatusCode);
        var body = await res.Content.ReadFromJsonAsync<ApiError>();
        Assert.Equal(code, body!.Error.Code);
    }
}
