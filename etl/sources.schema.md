# `etl/sources.json` — field spec (PROJECT_PLAN §6.13)

The per-state source registry: the **single source of truth** for which data sources exist per
state and every per-state parameter. Read by [`scripts/etl/registry_lib.sh`](../scripts/etl/registry_lib.sh)
(jq). The 🔒 invariant: **adding a state = one entry here** (+ a classifier mapping only for a
genuinely new attribute vocabulary); the engine, tiles, and UI never change.

Top-level: `{ "sources": [ …entries… ] }`. Each entry:

| Field | Req | Applies to | Meaning |
|---|---|---|---|
| `key` | ✔ | all | Stable `source_key`. Used everywhere as the lookup key and stamped into rows / `data_sources`. Never renamed. |
| `role` | ✔ | all | One of `base` \| `confirm_open` \| `claims` \| `reference`. Fixed vocabulary (the role table in §6.13). |
| `states` | ✔ | all | Array of 2-letter codes this source covers. The supported-state union is derived from these (canonical order = first appearance in the file; `padus` lists all in order). |
| `access` | ✔ | all | How to pull it — see below. |
| `loader` | ✔ | non-base | Path to the pull adapter (`scripts/etl/pull_sma.sh`, `pull_ugrc.sh`, `pull_calfire.sh`, …). For `base`/`reference` it may live under `access.loader` instead. |
| `sql` | ✔ | confirm_open | `"generated"` (built by `gen_confirm_open.sh` from the template) **or** a committed path (`scripts/etl/confirm_open_ca.sql`) for bespoke sources. |
| `classify` | ✔ | base | `{ fn, args }` — the SQL classifier function + the columns it reads. |
| `confirm` | ✔ | confirm_open | The confirm-open parameters — see below. |
| `serve` | ✔ | reference | `{ table, geom }` — the display-only `tiles.<key>` table it builds. NEVER touches `legality_polygons`. |
| `details` |   | reference | Optional second, *additive* loader that enriches the served table (e.g. MRDS related-table popup detail). `{ loader, source, tables, join_key, note }` — the pull adapter path, its bulk/query URL (single source of truth, read via `reg_raw`), the source tables it consumes, the column the related tables join on, and a human note. Purely display; never feeds the engine. |
| `attribution` | ✔ | all | Human credit line (map + panel). |
| `vintage` | ✔ | all | Canonical provenance string. **One** per source — baked into both the polygons (`data_vintage`) and `data_sources.vintage`. |
| `upstream_ref` | ✔ | all | URL or service name for freshness/provenance (`check_upstream`, `data_sources`). |
| `max_age_days` | ✔ | all | Staleness threshold (`null` = static source). |
| `license` | ✔ | all | License / terms. |
| `refresh` |   | claims | e.g. `"nightly"`. |

### `access`
| Field | Meaning |
|---|---|
| `type` | `arcgis_rest` (paginated GeoJSON query) or `download` (bulk GDB/zip/parquet). |
| `url` | The query endpoint (`arcgis_rest`) or the download/catalog URL. |
| `fields` | Attribute columns to pull (`reg_fields_csv` joins with commas). |
| `page` | ArcGIS page size (typically 2000). |
| `where` | Optional server-side filter (e.g. MRDS `CODE_LIST LIKE '%AU%'`). |
| `loader` | For `base`/`reference`: the pull/load script. |
| `layer` | Optional layer name (PAD-US combined layer, etc.). |
| `hu4_list` | (waterways) The per-HU4 list `pull_nhdplus_hr.sh` iterates. |
| `sources` | (access) Multi-source composite: the sub-source list `pull_access.sh` iterates — each with `id`, `kind` (`download`\|`arcgis_rest`), `staging`, and per-kind params (`zip_match`/`layer_match`/`rest_fallback` for FSGeodata GDBs; `url`/`layers`/`fields`/`page` for paged REST). One registry entry still = one served overlay (`tiles.access`); the sub-list is the loader's iteration detail, mirroring `hu4_list`. |

### `confirm` (confirm_open sources)
| Field | Meaning |
|---|---|
| `staging` | The `staging.<t>` table the loader writes (`staging.sma_nv`, `staging.ugrc_ownership`). |
| `public_predicate` | **The load-bearing per-state judgment.** A SQL boolean over the layer's owner/manager column that selects PUBLIC land. Derived by inspecting the live layer's code domain. Getting it wrong silently mis-paints legality. |
| `buffer_m` | Buffer distance (m) that absorbs boundary-generalization mismatch (100). |
| `crs` | Metric CRS for buffering (5070 CONUS Albers default; CA=3310, UT=26912). A coastal/edge state may warrant a state-plane/UTM choice. |
| `sliver_min_m2` | Drop confirm-open polygons below this area (source-resolution dependent: cadastral 500, GCDB/PLSS 1000, generalized 2000). |
| `carve_private` | Optional SQL predicate for parcels to subtract back out of the public buffer (affirmative private/tribal), so adjacency never blankets a known-not-public parcel. `null` for public-only layers. |
| `schema_cols` | Columns `assert_schema` checks exist after the pull. |

> Values are transcribed verbatim from the scripts they replaced;
> [`scripts/test/registry_roundtrip.sh`](../scripts/test/registry_roundtrip.sh) proves it.
> Runbook for adding a state: [`docs/ADD_A_STATE.md`](../docs/ADD_A_STATE.md).
