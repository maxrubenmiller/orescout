using System.Net;
using System.Net.Http.Json;
using OreScout.Api.Models;
using OreScout.Api.Tests.Infrastructure;

namespace OreScout.Api.Tests;

public class ApiKeyMiddlewareTests(ApiFactory factory) : IClassFixture<ApiFactory>
{
    [Fact]
    public async Task Missing_key_is_rejected_with_401()
    {
        var res = await factory.CreateClient().GetAsync("/api/v1/assessment?lat=39.5&lng=-117");

        Assert.Equal(HttpStatusCode.Unauthorized, res.StatusCode);
        var body = await res.Content.ReadFromJsonAsync<ApiError>();
        Assert.Equal("unauthorized", body!.Error.Code);
    }

    [Fact]
    public async Task Wrong_key_is_rejected_with_401()
    {
        var client = factory.CreateClient();
        client.DefaultRequestHeaders.Add("X-Api-Key", "not-the-key");

        var res = await client.GetAsync("/api/v1/assessment?lat=39.5&lng=-117");

        Assert.Equal(HttpStatusCode.Unauthorized, res.StatusCode);
    }

    [Fact]
    public async Task Valid_key_reaches_the_endpoint()
    {
        var res = await factory.CreateAuthedClient().GetAsync("/api/v1/assessment?lat=39.5&lng=-117");

        Assert.Equal(HttpStatusCode.OK, res.StatusCode);
        var body = await res.Content.ReadFromJsonAsync<AssessmentResponse>();
        Assert.Equal("GREEN", body!.CollectingStatus);
    }

    [Fact]
    public async Task Health_probe_is_exempt_from_the_key()
    {
        // No database in this test host, so health may report the dependency as down —
        // the point is that the middleware lets the request through instead of returning 401.
        var res = await factory.CreateClient().GetAsync("/api/v1/health");

        Assert.NotEqual(HttpStatusCode.Unauthorized, res.StatusCode);
    }
}
