// Gateable capability ids — mirror the API feature catalog (PROJECT_PLAN §6.14 / decision #45).
// KEEP IN SYNC with src/OreScout.Api/Entitlements/FeatureCatalog.cs. Reference these constants
// (never raw strings) when checking entitlement so a typo is a compile error, not a silent unlock.
export const FEATURES = {
  layerWaterways: 'layer.waterways',
  layerMrds: 'layer.mrds',
  layerProspectivity: 'layer.prospectivity',
  layerClaims: 'layer.claims',
  exportGpx: 'export.gpx',
  routingAccess: 'routing.access',
} as const;

export type FeatureId = (typeof FEATURES)[keyof typeof FEATURES];
