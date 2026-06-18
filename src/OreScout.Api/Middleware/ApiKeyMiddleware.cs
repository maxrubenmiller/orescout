using System.Text.Json;
using OreScout.Api.Models;

namespace OreScout.Api.Middleware;

/// <summary>
/// POC auth (PROJECT_PLAN.md §6.2): a single static key on the X-Api-Key header.
/// NOT a security control — it only deters trivial drive-by hits for a private,
/// single-user POC. /api/v1/health is exempt so monitoring can reach it.
/// Replaced wholesale by JWT bearer when OreScout goes public (§6.2 migration).
/// </summary>
public class ApiKeyMiddleware(RequestDelegate next, IConfiguration config, ILogger<ApiKeyMiddleware> log)
{
    private const string HeaderName = "X-Api-Key";

    // Env var wins over appsettings (prod sets ORESCOUT_API_KEY).
    private readonly string? _expectedKey =
        Environment.GetEnvironmentVariable("ORESCOUT_API_KEY") ?? config["ApiKey"];

    public async Task InvokeAsync(HttpContext context)
    {
        var path = context.Request.Path;

        // Exempt the readiness probe.
        if (path.StartsWithSegments("/api/v1/health"))
        {
            await next(context);
            return;
        }

        if (string.IsNullOrEmpty(_expectedKey))
        {
            log.LogError("No API key configured (ApiKey / ORESCOUT_API_KEY). Rejecting all requests.");
            await WriteError(context, StatusCodes.Status500InternalServerError,
                "server_misconfigured", "API key is not configured.");
            return;
        }

        if (!context.Request.Headers.TryGetValue(HeaderName, out var provided)
            || !string.Equals(provided, _expectedKey, StringComparison.Ordinal))
        {
            await WriteError(context, StatusCodes.Status401Unauthorized,
                "unauthorized", "Missing or invalid X-Api-Key header.");
            return;
        }

        await next(context);
    }

    private static async Task WriteError(HttpContext ctx, int status, string code, string message)
    {
        ctx.Response.StatusCode = status;
        ctx.Response.ContentType = "application/json";
        var payload = new ApiError(new ApiErrorBody(code, message));
        await ctx.Response.WriteAsync(JsonSerializer.Serialize(payload,
            new JsonSerializerOptions(JsonSerializerDefaults.Web)));
    }
}
