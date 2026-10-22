namespace OreScout.Api.Entitlements;

/// <summary>
/// Who a request is acting as, for entitlement decisions. TODAY there are no user accounts — the POC
/// authenticates with a single static API key (§6.2) — so every request resolves to
/// <see cref="Anonymous"/> with the implicit full plan. When the JWT identity migration lands
/// (§6.2 / decision #11) build this from the authenticated principal's claims in
/// <see cref="FromHttpContext"/>; call sites do not change. docs/planning/PROJECT_PLAN.md §6.14.
/// </summary>
public record EntitlementPrincipal(string? UserId, string Plan)
{
    /// <summary>The implicit plan while there are no accounts: full access.</summary>
    public const string FullPlan = "full";

    /// <summary>The single POC principal — no identity yet, full access.</summary>
    public static readonly EntitlementPrincipal Anonymous = new(UserId: null, Plan: FullPlan);

    /// <summary>
    /// Resolve the acting principal for a request. Single-user today (always <see cref="Anonymous"/>);
    /// read <c>ctx.User</c> claims here once JWT auth is in place (§6.2).
    /// </summary>
    public static EntitlementPrincipal FromHttpContext(HttpContext ctx) => Anonymous;
}
