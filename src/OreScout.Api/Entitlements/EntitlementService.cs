namespace OreScout.Api.Entitlements;

/// <summary>
/// The single server-side entitlement chokepoint (docs/planning/PROJECT_PLAN.md §6.14 / decision #45). Every
/// paywall decision routes through here. TODAY it is a stub that grants everything — the seam exists
/// so that gating a feature later is a change *in this service*, not scattered across feature code.
/// </summary>
public interface IEntitlementService
{
    /// <summary>May <paramref name="principal"/> use the capability <paramref name="featureId"/>? (ids: <see cref="FeatureCatalog"/>).</summary>
    bool IsEntitled(EntitlementPrincipal principal, string featureId);

    /// <summary>The capability ids <paramref name="principal"/> is entitled to — drives <c>/api/v1/entitlements</c>.</summary>
    IReadOnlyCollection<string> EntitledFeatures(EntitlementPrincipal principal);
}

/// <summary>
/// Stub implementation: grants every catalogued capability to every principal. Intentional
/// (decision #45 — the seam, not the paywall). To turn the paywall ON, replace this registration
/// with an implementation that compares <see cref="EntitlementPrincipal.Plan"/> against each
/// feature's <see cref="Feature.Tier"/> (from <see cref="FeatureCatalog"/>). Nothing else changes.
/// </summary>
public sealed class GrantAllEntitlementService : IEntitlementService
{
    public bool IsEntitled(EntitlementPrincipal principal, string featureId) => true;

    public IReadOnlyCollection<string> EntitledFeatures(EntitlementPrincipal principal) =>
        FeatureCatalog.All.Select(f => f.Id).ToArray();
}
