using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using OreScout.Api.Models;
using OreScout.Api.Services;

namespace OreScout.Api.Tests.Infrastructure;

/// <summary>
/// Hosts the real API pipeline (CORS, exception handler, API-key middleware, endpoints) in memory.
/// The assessment engine is swapped for a fake, so these tests need no Postgres/PostGIS and run in CI.
/// Requests that never reach the database (auth, validation) exercise the production code unchanged.
/// </summary>
public sealed class ApiFactory : WebApplicationFactory<Program>
{
    public const string ApiKey = "test-key";

    public FakeAssessmentService Assessment { get; } = new();

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.UseEnvironment("Testing");
        builder.UseSetting("ApiKey", ApiKey);
        // Point at a port nothing listens on, so a test can never write to a developer's real
        // database — anything that slips past validation fails instead of persisting.
        builder.UseSetting("ConnectionStrings:Postgres",
            "Host=127.0.0.1;Port=1;Database=none;Username=none;Password=none;Timeout=2");
        builder.ConfigureServices(services =>
        {
            services.RemoveAll<IAssessmentService>();
            services.AddSingleton<IAssessmentService>(Assessment);
        });
    }

    public HttpClient CreateAuthedClient()
    {
        var client = CreateClient();
        client.DefaultRequestHeaders.Add("X-Api-Key", ApiKey);
        return client;
    }
}

public sealed class FakeAssessmentService : IAssessmentService
{
    public int Calls { get; private set; }

    public Task<AssessmentResponse> AssessAsync(double lat, double lng, CancellationToken ct)
    {
        Calls++;
        return Task.FromResult(new AssessmentResponse
        {
            CollectingStatus = "GREEN",
            CollectingStatusReason = $"fake verdict for {lat},{lng}",
            Disclaimer = "test",
            AssessmentDate = DateTimeOffset.UnixEpoch,
        });
    }
}
