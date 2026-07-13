namespace OreScout.Api.Models;

// ---- Assessment (canonical response — PROJECT_PLAN.md §6.2) -----------------
// Serialized camelCase (ASP.NET web defaults). warnings/cannotModel/dataGaps are
// always arrays (never null). collectingStatus ∈ GREEN|YELLOW|RED|OUT_OF_REGION.
// ambiguityType ∈ KNOWN|UNKNOWN|null (non-null only when collectingStatus=YELLOW).
public record AssessmentResponse
{
    public required string CollectingStatus { get; init; }
    public string? AmbiguityType { get; init; }
    public required string CollectingStatusReason { get; init; }
    public string? LandManager { get; init; }
    public string? UnitName { get; init; }
    public string? ProtectionStatus { get; init; }
    public List<ActiveClaim>? ActiveClaims { get; init; }   // null = NOT checked (see DataGaps)
    public List<string> Warnings { get; init; } = [];
    public List<string> CannotModel { get; init; } = [];
    public List<string> DataGaps { get; init; } = [];
    public string? DataVintage { get; init; }
    public required string Disclaimer { get; init; }
    public DateTimeOffset AssessmentDate { get; init; }
}

public record ActiveClaim(
    string SerialNumber,
    string? ClaimName,
    string? Type,
    string? Status,      // CSE_DISP: Active | Pending | ...
    string MlrsUrl);

// ---- Standard copy (§6.4 / §8.2) -------------------------------------------
public static class AssessmentText
{
    public static readonly string[] CannotModel =
    [
        "BLM Resource Management Plan local rules",
        "Per-proclamation National Monument restrictions",
        "ESA endangered species habitat closures",
        "Riparian and stream setback rules"
    ];

    public const string Disclaimer =
        "This assessment is for casual hobbyist use (hand panning, sluicing, and surface " +
        "collecting) only. It does not account for BLM Resource Management Plan local rules, " +
        "National Monument proclamation-specific restrictions, or state-specific permit " +
        "requirements. Verify with the managing agency before visiting. Data sourced from BLM " +
        "and USGS public datasets.";
}

// ---- Pins (§4.2 / §6.2) ----------------------------------------------------
public record CreatePinRequest(double Lat, double Lng, string Title, string? Notes, string? Status);
public record UpdatePinRequest(string Title, string? Notes, string Status);

public record PinResponse(
    Guid Id, double Lat, double Lng, string Title, string? Notes, string Status,
    string[] Tags, object? AssessmentSnapshot, DateTimeOffset? AssessmentDate,
    DateTimeOffset CreatedAt, DateTimeOffset UpdatedAt);

// ---- Geocode / Meta / Health ----------------------------------------------
public record GeocodeResult(string Label, double Lat, double Lng, string? Type);
public record GeocodeResponse(List<GeocodeResult> Results);

public record MetaResponse(
    string? PadUsVersion, string? PadUsDate, string? SmaDate, string? ClaimsAsOf,
    string[] SupportedStates, List<DataSourceInfo> DataSources);

/// <summary>
/// One row of the freshness registry (public.data_sources; docs/DATA_REFRESH_PLAN.md). Additive:
/// the legacy top-level meta fields stay for compatibility; new consumers read this list.
/// MaxAgeDays null = static source (never stale). Stale is computed server-side so every client
/// shows the same verdict.
/// </summary>
public record DataSourceInfo(
    string SourceKey, string? Role, string? Vintage, DateTimeOffset? RefreshedAt,
    int? MaxAgeDays, string? LastGateStatus, bool Stale);

public record HealthResponse(string Status, HealthChecks Checks);
public record HealthChecks(string Postgis, string Tileserv);

// ---- Entitlements (§6.14 / decision #45) -----------------------------------
// One catalogued capability + whether the caller may use it. `Entitled` is the paywall answer
// (all true today); `Tier` ("free"|"paid") lets the UI label paid features. The frontend renders
// its layer list + lock affordance from this list — see web/src/hooks.ts (useEntitlements).
public record FeatureEntitlement(string Id, string Label, string Tier, bool Entitled);
public record EntitlementsResponse(List<FeatureEntitlement> Features);

public record ApiError(ApiErrorBody Error);
public record ApiErrorBody(string Code, string Message);
