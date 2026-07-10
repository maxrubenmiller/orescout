#!/usr/bin/env bash
# Run the Tier-A classifier fixtures inside the running Postgres container.
# Exits non-zero if any fixture fails (ON_ERROR_STOP=1 + RAISE EXCEPTION).
#
# This is a HOST script (it shells into the container) and deliberately lives
# OUTSIDE ./db so the postgres entrypoint never tries to execute it during init.
#
# Usage:  ./scripts/run-fixtures.sh        (requires `docker compose up -d` first)
set -euo pipefail

# Feed via stdin (not the container's /docker-entrypoint-initdb.d mount) so the fixtures of THIS
# checkout run — the mount always points at the main working tree, which silently runs stale
# fixtures when testing from a branch/worktree (IMP-08).
cd "$(dirname "$0")/.."
docker compose exec -T postgres \
  psql -v ON_ERROR_STOP=1 -U postgres -d miningapp \
  < db/fixtures/classifier_test.sql
