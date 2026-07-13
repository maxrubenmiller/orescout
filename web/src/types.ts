// Canonical API types (mirror PROJECT_PLAN.md §6.2). Keep in sync with the C# DTOs.

export type CollectingStatus = 'GREEN' | 'YELLOW' | 'RED' | 'OUT_OF_REGION';
export type AmbiguityType = 'KNOWN' | 'UNKNOWN' | null;

export interface ActiveClaim {
  serialNumber: string;
  claimName: string | null;
  type: string | null;
  status: string | null; // CSE_DISP: Active | Pending | Filed | ...
  mlrsUrl: string;
}

export interface Assessment {
  collectingStatus: CollectingStatus;
  ambiguityType: AmbiguityType;
  collectingStatusReason: string;
  landManager: string | null;
  unitName: string | null;
  protectionStatus: string | null;
  activeClaims: ActiveClaim[] | null; // null = not checked
  warnings: string[];
  cannotModel: string[];
  dataGaps: string[];
  dataVintage: string | null;
  disclaimer: string;
  assessmentDate: string;
}

export type PinStatus = 'want_to_visit' | 'visited';

export interface Pin {
  id: string;
  lat: number;
  lng: number;
  title: string;
  notes: string | null;
  status: PinStatus;
  tags: string[];
  assessmentSnapshot: Assessment | null;
  assessmentDate: string | null;
  createdAt: string;
  updatedAt: string;
}

export interface CreatePinRequest {
  lat: number;
  lng: number;
  title: string;
  notes?: string | null;
  status?: PinStatus;
}

export interface GeocodeResult {
  label: string;
  lat: number;
  lng: number;
  type: string | null;
}

export interface Meta {
  padUsVersion: string | null;
  padUsDate: string | null;
  smaDate: string | null;
  claimsAsOf: string | null;
  supportedStates: string[];
  dataSources: DataSourceInfo[];
}

/** One freshness-registry row (public.data_sources; docs/DATA_REFRESH_PLAN.md).
 *  `stale` is computed server-side; maxAgeDays null = static source, never stale. */
export interface DataSourceInfo {
  sourceKey: string;
  role: string | null;
  vintage: string | null;
  refreshedAt: string | null;
  maxAgeDays: number | null;
  lastGateStatus: string | null;
  stale: boolean;
}

export interface LatLng {
  lat: number;
  lng: number;
}

/** One gateable capability + whether the caller may use it (PROJECT_PLAN §6.14 / decision #45).
 *  `entitled` is the paywall answer (all true today); `tier` labels paid features. Mirror the
 *  C# FeatureEntitlement DTO. */
export interface FeatureEntitlement {
  id: string;
  label: string;
  tier: 'free' | 'paid';
  entitled: boolean;
}

export interface Entitlements {
  features: FeatureEntitlement[];
}
