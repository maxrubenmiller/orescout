namespace OreScout.Api.Entitlements;

/// <summary>
/// Gateable capability tiers. Everything ships <see cref="Free"/> today; flipping a capability to
/// <see cref="Paid"/> (and teaching <see cref="IEntitlementService"/> to read the account's plan) is
/// how a feature goes behind the paywall — with no change to the feature's own code.
/// docs/planning/PROJECT_PLAN.md §6.14 / decision #45.
/// </summary>
public enum FeatureTier { Free, Paid }

/// <summary>One gateable capability. <see cref="Id"/> is the stable wire identifier shared with the frontend.</summary>
public record Feature(string Id, string Label, FeatureTier Tier);

/// <summary>
/// THE canonical list of gateable capabilities (docs/planning/PROJECT_PLAN.md §6.14). Single source of truth: the
/// API gates against these ids, and the frontend renders its layer list + lock affordance from
/// <c>/api/v1/entitlements</c>, which is derived from this catalog. To make a new capability
/// paywall-ready: add it here, then gate it at its serving point with
/// <c>IEntitlementService.IsEntitled(principal, Features.X)</c>. Ids are namespaced by kind
/// (<c>layer.* / export.* / routing.*</c>). Boolean capabilities only for now; quota-style ones
/// (e.g. a future <c>pins.max</c>) will extend this model when needed.
/// </summary>
public static class FeatureCatalog
{
    // Map overlays — served as tiles (browser → pg_tileserv). Gating these enforces at the future
    // authenticated tile proxy, not the API (tiles bypass the API — §6.14).
    public const string LayerWaterways = "layer.waterways";
    public const string LayerMrds = "layer.mrds";
    public const string LayerProspectivity = "layer.prospectivity";
    public const string LayerClaims = "layer.claims";
    public const string LayerAccess = "layer.access";

    // API-served capabilities — gate at the endpoint.
    public const string ExportGpx = "export.gpx";

    // Future — the access-routing feature (MVUM/trails, see docs/research/DATA_SOURCE_INVESTIGATION_MVUM_TRAILS.md).
    public const string RoutingAccess = "routing.access";

    /// <summary>All gateable capabilities. Everything <see cref="FeatureTier.Free"/> today (decision #45 — the seam, not the paywall).</summary>
    public static readonly IReadOnlyList<Feature> All =
    [
        new(LayerWaterways,     "Waterways overlay",            FeatureTier.Free),
        new(LayerMrds,          "Gold occurrences (MRDS)",      FeatureTier.Free),
        new(LayerProspectivity, "Prospecting potential",        FeatureTier.Free),
        new(LayerClaims,        "Active mining claims",         FeatureTier.Free),
        new(LayerAccess,        "Access & trails overlay",      FeatureTier.Free),
        new(ExportGpx,          "GPX export",                   FeatureTier.Free),
        new(RoutingAccess,      "Access routing (MVUM/trails)", FeatureTier.Free),
    ];
}
