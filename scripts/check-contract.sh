#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

legacy_network_pattern='fieldtrack''_network'
legacy_config_pattern='fieldtrack''\.conf'
legacy_slot_pattern='/var/run/api''/active-slot'

log_info()  { printf '[check-contract] INFO  %s\n' "$*"; }
log_error() { printf '[check-contract] ERROR %s\n' "$*" >&2; }
log_ok()    { printf '[check-contract] OK    %s\n' "$*"; }

assert_absent() {
  local description="$1"
  local pattern="$2"
  # Scope: scripts/*.sh only — README, docs, and workflows are not subject to
  # these naming-contract rules.
  if grep -n --binary-files=without-match -E "$pattern" scripts/*.sh; then
    log_error "Found forbidden ${description}"
    exit 1
  fi
}

# assert_absent_except <description> <pattern> <exclusion-regex>
# Like assert_absent but ignores lines matching exclusion-regex.
# Used for paths that are legitimately defined in one place (e.g., bootstrap.sh
# declares the VPS default; no other script may use it as a bare path).
assert_absent_except() {
  local description="$1"
  local pattern="$2"
  local exclusion="$3"
  if grep -n --binary-files=without-match -E "$pattern" scripts/*.sh \
       | grep -vE "$exclusion"; then
    log_error "Found forbidden ${description}"
    exit 1
  fi
}

assert_contains() {
  local file_path="$1"
  local expected="$2"

  if ! grep -Fq "$expected" "$file_path"; then
    log_error "Expected '${expected}' in ${file_path}"
    exit 1
  fi
}

assert_file_exists() {
  local file_path="$1"

  if [ ! -f "$file_path" ]; then
    log_error "Required file missing: ${file_path}"
    exit 1
  fi
}

cd "${INFRA_DIR}"

log_info "Checking for forbidden legacy contract references..."
assert_absent "legacy Docker network name" "${legacy_network_pattern}"
assert_absent "legacy nginx config name" "${legacy_config_pattern}"
assert_absent "legacy volatile slot path" "${legacy_slot_pattern}"
log_ok "No legacy contract references found"

log_info "Checking canonical file names..."
assert_file_exists "nginx/api.conf"
assert_file_exists "nginx/api.maintenance.conf"
log_ok "Canonical nginx config files exist"

log_info "Checking compose network contract..."
assert_contains "docker-compose.nginx.yml" "api_network:"
assert_contains "docker-compose.nginx.yml" "external: true"
assert_contains "docker-compose.redis.yml" "api_network:"
assert_contains "docker-compose.redis.yml" "external: true"
assert_contains "docker-compose.monitoring.yml" "api_network:"
assert_contains "docker-compose.monitoring.yml" "external: true"
log_ok "Compose files use external api_network"

log_info "Checking script contract..."
# Ensure scripts reference canonical network and follow contract
assert_contains "scripts/bootstrap.sh" "api_network"

# Detect hardcoded canonical paths in scripts/*.sh.
# The ONLY permitted occurrences are:
#   - bootstrap.sh: defines STATE_DIR, LOG_DIR, and EXPECTED_INFRA_ROOT as VPS defaults
#   - nginx-sync.sh: uses ${VAR:-default} env-override syntax for all three paths
# All other scripts must reference ${INFRA_ROOT}, ${LOG_DIR}, ${STATE_DIR} — never bare paths.
assert_absent_except "hardcoded canonical infra path" \
  "/opt/infra" \
  "(INFRA_ROOT.*:-/opt/infra|EXPECTED_INFRA_ROOT=['\"/]*/opt/infra)"
assert_absent_except "hardcoded fieldtrack log path" \
  "/var/log/fieldtrack" \
  "LOG_DIR.*=.*[-:\"']/var/log/fieldtrack"
assert_absent_except "hardcoded fieldtrack state path" \
  "/var/lib/fieldtrack" \
  "STATE_DIR.*=.*[-:\"']/var/lib/fieldtrack"

# bootstrap.sh MUST define the canonical VPS state default explicitly.
assert_contains "scripts/bootstrap.sh" "STATE_DIR=\"/var/lib/fieldtrack\""

# Guard against legacy slot-file usage in nginx-sync (slot-based routing removed).
if grep -Fq "active-slot" "scripts/nginx-sync.sh"; then
  log_error "scripts/nginx-sync.sh must not reference active-slot (slot-based routing was removed)"
  exit 1
fi
log_ok "nginx-sync.sh contains no legacy slot-file references"

# Ensure monitoring script references the expected compose manifest.
assert_contains "scripts/monitoring-sync.sh" "docker-compose.monitoring.yml"
log_ok "Scripts match the shared infra contract"

# Ensure runtime nginx directories are present in the repo layout (keeps git clone deterministic).
# These .gitkeep files guarantee the directory layout is present after clone.
log_info "Ensuring runtime nginx directories are tracked"
assert_file_exists "nginx/live/.gitkeep"
assert_file_exists "nginx/backup/.gitkeep"
log_ok "Runtime nginx directories are present and tracked"

log_info "Checking monitoring targets..."
assert_contains "docker-compose.monitoring.yml" "REDIS_ADDR=redis:6379"
assert_contains "prometheus/prometheus.yml" "\"api-blue:3000\""
assert_contains "prometheus/prometheus.yml" "\"api-green:3000\""
assert_contains "prometheus/prometheus.yml" "\"redis-exporter:9121\""
log_ok "Monitoring targets match canonical names"

log_info "Checking contract documentation..."
assert_file_exists "docs/CONTRACT.md"
assert_contains "docs/CONTRACT.md" "Network: api_network"
assert_contains "docs/CONTRACT.md" "Containers: api-blue, api-green, redis, nginx"
assert_contains "docs/CONTRACT.md" "Routing: health-based (api-blue, api-green)"
assert_contains "docs/CONTRACT.md" "nginx config: api.conf"
assert_contains "docs/CONTRACT.md" "Redis: redis:6379"
log_ok "Contract documentation is present"

log_ok "Infra contract checks passed"
