import type { LatLng } from './types';

// Parse a coordinate string. Handles decimal ("39.5, -117.0") and DMS
// ("39°30'N 117°00'W", "39 30 00 N", "N39 30"). Returns null if not parseable
// (caller falls back to geocoding). PROJECT_PLAN.md §4.3.

const DECIMAL = /^\s*(-?\d+(?:\.\d+)?)\s*[, ]\s*(-?\d+(?:\.\d+)?)\s*$/;

export function parseCoordinates(input: string): LatLng | null {
  const dec = input.match(DECIMAL);
  if (dec) {
    const lat = parseFloat(dec[1]);
    const lng = parseFloat(dec[2]);
    if (inRange(lat, lng)) return { lat, lng };
    return null;
  }
  return parseDms(input);
}

function inRange(lat: number, lng: number): boolean {
  return lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180;
}

// One DMS component, e.g. "39°30'15\"N" / "N 39 30" / "117 00 W"
const DMS_PART =
  /([NSEW])?\s*(\d+(?:\.\d+)?)\s*[°:\s]\s*(\d+(?:\.\d+)?)?\s*['′:\s]?\s*(\d+(?:\.\d+)?)?\s*["″]?\s*([NSEW])?/i;

function parseDms(input: string): LatLng | null {
  // Split into two halves on the hemisphere boundary or whitespace between groups.
  const parts = splitTwo(input);
  if (!parts) return null;
  const a = parseDmsPart(parts[0]);
  const b = parseDmsPart(parts[1]);
  if (!a || !b) return null;

  let lat: number | null = null;
  let lng: number | null = null;
  for (const p of [a, b]) {
    if (p.hemi === 'N' || p.hemi === 'S') lat = p.hemi === 'S' ? -p.value : p.value;
    else if (p.hemi === 'E' || p.hemi === 'W') lng = p.hemi === 'W' ? -p.value : p.value;
  }
  // If no hemisphere letters, assume "lat lng" order.
  if (lat == null && lng == null) { lat = a.value; lng = b.value; }
  if (lat == null || lng == null || !inRange(lat, lng)) return null;
  return { lat, lng };
}

function splitTwo(input: string): [string, string] | null {
  const t = input.trim();
  // Prefer splitting between a hemisphere letter and the next number.
  const m = t.match(/^(.*?[NSEW])\s*[, ]?\s*([\d NSEW°'":.′″].*)$/i);
  if (m) return [m[1], m[2]];
  const parts = t.split(/\s*,\s*|\s{2,}/);
  if (parts.length === 2) return [parts[0], parts[1]];
  return null;
}

function parseDmsPart(s: string): { value: number; hemi: string | null } | null {
  const m = s.match(DMS_PART);
  if (!m) return null;
  const deg = parseFloat(m[2]);
  if (Number.isNaN(deg)) return null;
  const min = m[3] ? parseFloat(m[3]) : 0;
  const sec = m[4] ? parseFloat(m[4]) : 0;
  const hemi = (m[1] || m[5] || '').toUpperCase() || null;
  return { value: deg + min / 60 + sec / 3600, hemi };
}
