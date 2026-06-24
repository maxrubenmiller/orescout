using System.Net.Sockets;
using System.Text.Json;
using Microsoft.AspNetCore.Diagnostics;
using Npgsql;
using OreScout.Api.Models;

namespace OreScout.Api.Middleware;

/// <summary>
/// The central 5xx chokepoint (PROJECT_PLAN.md §6.3, decisions #12 + #33). It splits failures into:
///   • a CORE DEPENDENCY being unavailable (PostGIS unreachable) → HTTP 503 + Retry-After (retryable),
///   • a genuine bug → HTTP 500,
/// logs every 5xx with method+path for prod alerting (503 pages infra; 500 is a dev-backlog bug), and
/// never leaks internals to the client. Keeps the canonical { error: { code, message } } shape so the
/// frontend ApiError parser is unaffected. Pairs with the /health readiness 503: readiness sheds the
/// instance from rotation, this covers the per-request race window before that happens (§6.3).
///
/// Intentional scope (decision #33): with a SINGLE core dependency, the 503 decision is made by
/// inspecting the exception chain. The cleaner "throw a typed ServiceUnavailableException at the call
/// site" pattern is deferred until the 2nd core dependency (auth/B2C) lands — premature for one.
/// Likewise NOT done now: RFC 9457 ProblemDetails (the bespoke error shape is contract; the frontend
/// depends on it) and transient-retry/Polly (a resilience layer on top of, not part of, this handler).
/// </summary>
public sealed class GlobalExceptionHandler(ILogger<GlobalExceptionHandler> log) : IExceptionHandler
{
    private static readonly JsonSerializerOptions Web = new(JsonSerializerDefaults.Web);
    private const string RetryAfterSeconds = "5";

    public async ValueTask<bool> TryHandleAsync(HttpContext ctx, Exception ex, CancellationToken ct)
    {
        // A client disconnect is not a server error — let the framework abort the request.
        if (ex is OperationCanceledException && ctx.RequestAborted.IsCancellationRequested)
            return false;

        var coreDown = IsCoreDependencyUnavailable(ex);

        log.LogError(ex, "{Outcome} on {Method} {Path}",
            coreDown ? "Core dependency unavailable -> 503" : "Unhandled exception -> 500",
            ctx.Request.Method, ctx.Request.Path);

        var (status, code, message) = coreDown
            ? (StatusCodes.Status503ServiceUnavailable, "service_unavailable",
               "A required service is temporarily unavailable. Please try again shortly.")
            : (StatusCodes.Status500InternalServerError, "internal_error",
               "An unexpected error occurred.");

        ctx.Response.StatusCode = status;
        ctx.Response.ContentType = "application/json";
        if (coreDown) ctx.Response.Headers.RetryAfter = RetryAfterSeconds;

        await ctx.Response.WriteAsync(
            JsonSerializer.Serialize(new ApiError(new ApiErrorBody(code, message)), Web), ct);
        return true;
    }

    /// <summary>
    /// PostGIS reachable-but-erroring vs. unreachable. A <see cref="PostgresException"/> means the
    /// server RESPONDED with an error (it is up) → a query/logic bug → 500. A connection-level
    /// <see cref="NpgsqlException"/> / <see cref="SocketException"/> / timeout means it could not be
    /// reached → 503. Walks the inner-exception chain (EF wraps Npgsql); the more specific
    /// PostgresException is checked first so real SQL bugs are never masked as "try again".
    /// </summary>
    private static bool IsCoreDependencyUnavailable(Exception ex)
    {
        for (Exception? e = ex; e is not null; e = e.InnerException)
        {
            if (e is PostgresException) return false;
            if (e is NpgsqlException or SocketException or TimeoutException) return true;
        }
        return false;
    }
}
