#!/usr/bin/env bash
set -euo pipefail

# infra/scripts/check-contract.sh
# Context-aware contract validation for the infra repository.
#
# - Allows comments and canonical variable definitions that reference
#   /opt/infra, /var/log/fieldtrack, /var/lib/fieldtrack
# - Detects hardcoded usage in executable script logic (scripts/*.sh)
# - Ensures required nginx templates and tracked runtime dirs are present
# - Ensures compose files reference external api_network
#
# Exit codes:
#  0 = OK
#  1 = Contract violation(s) detected

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${INFRA_DIR}"

log_info()  { printf '[check-contract] INFO  %s\n' "$*"; }
log_warn()  { printf '[check-contract] WARN  %s\n' "$*" >&2; }
log_error() { printf '[check-contract] ERROR %s\n' "$*" >&2; }
log_ok()    { printf '[check-contract] OK    %s\n' "$*"; }

assert_contains() {
  local file_path="$1"; shift
  local expected="$*"
  if ! grep -Fq -- "$expected" "$file_path"; then
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

assert_dir_exists_tracked() {
  local dir_path="$1"
  local marker="$2"
  if [ ! -d "${dir_path}" ]; then
    log_error "Required directory missing: ${dir_path}"
    exit 1
  fi
  if [ ! -f "${dir_path}/${marker}" ]; then
    log_error "Repository must track ${dir_path}/${marker} (create an empty .gitkeep)"
    exit 1
  fi
}

# -------------------------
# Helper: context-aware detection of hardcoded paths inside scripts
# -------------------------
# This function searches only within script files (scripts/*.sh) and reports
# occurrences where an absolute path is used in executable logic. It allows:
#  - comment lines (beginning with #)
#  - canonical variable definitions / defaults, e.g.:
#      INFRA_ROOT="${INFRA_ROOT:-/opt/infra}"
#      LOG_DIR="/var/log/fieldtrack"
#  - lines containing the textual label "CANONICAL PATH" or similar doc strings
#
# It flags lines that reference the forbidden literal but are not one of the
# allowed patterns above.
assert_no_hardcoded_usage() {
  local matches

  # Collect candidate matches from script files (filename:lineno:content).
  # Then filter out lines where the content portion (after filename:lineno:) is a comment,
  # and also ignore canonical variable definitions.
  matches=$(grep -nE '/opt/infra|/var/log/fieldtrack|/var/lib/fieldtrack' scripts/*.sh || true)
  matches=$(printf '%s\n' "${matches}" \
    | grep -vE '^[^:]+:[0-9]+:\s*#' \
    | grep -vE '\b(INFRA_ROOT|LOG_DIR|STATE_DIR|EXPECTED_INFRA_ROOT)\b' \
    | grep -vF "$(basename "$0")" || true)

  if [[ -n "$matches" ]]; then
    echo "[check-contract] ERROR Hardcoded path usage found:"
    echo "$matches"
    exit 1
  fi
}

# -------------------------
# Begin checks
# -------------------------
log_info "Running infra contract checks in ${INFRA_DIR}"

# 1) Basic required files (templates)
log_info "Checking canonical nginx config files..."
assert_file_exists "nginx/api.conf"
assert_file_exists "nginx/api.maintenance.conf"
log_ok "Canonical nginx config files exist"

# 2) Compose and networking contract
log_info "Checking compose network contract..."
assert_contains "docker-compose.nginx.yml" "api_network:"
assert_contains "docker-compose.nginx.yml" "external: true"
assert_contains "docker-compose.redis.yml" "api_network:"
assert_contains "docker-compose.redis.yml" "external: true"
# monitoring compose is optional in minimal setups, but if present should use the network
if [ -f docker-compose.monitoring.yml ]; then
  assert_contains "docker-compose.monitoring.yml" "api_network:"
  assert_contains "docker-compose.monitoring.yml" "external: true"
fi
log_ok "Compose files use external api_network where present"

# 3) Scripts contract: check hardcoded absolute paths in logic (scripts only)
assert_no_hardcoded_usage

# Optional improvement: also scan GitHub Actions workflow script blocks for
# hardcoded paths. Workflows often embed shell scripts under "script:" which
# can contain executable commands; we should flag non-commented occurrences
# there as well. To avoid false positives (env: keys, docs, etc.) only extract
# the literal script: | blocks and scan their contents.
# Scan only script: | blocks (SSH action payloads) — not env: keys, run: blocks, or YAML docs.
# infra-deploy.yml is the VPS provisioning script and must reference /opt/infra directly
# (cd /opt/infra, git clone /opt/infra, etc.) — exclude it for the same reason we exclude
# check-contract.sh from the scripts scan: it legitimately uses the canonical path by design.
# Any other workflow file that introduces a hardcoded path in a script: | block will be caught.
log_info "Scanning GitHub Actions workflow script:| blocks for hardcoded paths..."
workflow_matches=$(awk '
  /script:[[:space:]]*\|/ { in_block=1; next }
  in_block && /^[^[:space:]]/ { in_block=0 }
  in_block { print FILENAME ":" FNR ":" $0 }
' .github/workflows/*.yml 2>/dev/null \
  | grep -vF 'infra-deploy.yml' \
  | grep -E '/opt/infra|/var/log/fieldtrack|/var/lib/fieldtrack' \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
  | grep -vE '\b(INFRA_ROOT|LOG_DIR|STATE_DIR|EXPECTED_INFRA_ROOT)\b' \
  || true)

if [ -n "${workflow_matches}" ]; then
  log_error "Hardcoded path usage found in GitHub Actions workflow script blocks:"
  printf '%s\n' "${workflow_matches}" >&2
  log_error "Use env vars (INFRA_ROOT/LOG_DIR/STATE_DIR) instead of hardcoded absolute paths."
  exit 1
fi
log_ok "No forbidden hardcoded paths found in workflow script blocks"

# 4) Script-level smoke checks
log_info "Checking script contract expectations..."
assert_contains "scripts/bootstrap.sh" "api_network"
# bootstrap is allowed to document the canonical defaults; assert it exposes STATE_DIR default
assert_contains "scripts/bootstrap.sh" "STATE_DIR=\"/var/lib/fieldtrack\""
log_ok "Bootstrap script documents canonical defaults"

# Ensure nginx-sync.sh no longer references legacy slot-file names
if grep -Fq "active-slot" "scripts/nginx-sync.sh" 2>/dev/null; then
  log_error "scripts/nginx-sync.sh must not reference active-slot (slot-based routing was removed)"
  exit 1
fi
log_ok "nginx-sync.sh contains no legacy slot-file references"

# 5) Ensure runtime nginx directories are tracked so clone produces the layout
log_info "Ensuring runtime nginx directories are tracked"
assert_dir_exists_tracked "nginx/live" ".gitkeep"
assert_dir_exists_tracked "nginx/backup" ".gitkeep"
log_ok "Runtime nginx directories are present and tracked"

# 6) Monitoring targets (if present)
if [ -f docker-compose.monitoring.yml ]; then
  log_info "Checking monitoring targets..."
  assert_contains "docker-compose.monitoring.yml" "REDIS_ADDR=redis:6379"
  if [ -f prometheus/prometheus.yml ]; then
    assert_contains "prometheus/prometheus.yml" "\"api-blue:3000\"" || true
    assert_contains "prometheus/prometheus.yml" "\"api-green:3000\"" || true
    assert_contains "prometheus/prometheus.yml" "\"redis-exporter:9121\"" || true
  fi
  log_ok "Monitoring targets look correct"
fi

# 7) Contract docs
log_info "Checking contract documentation..."
assert_file_exists "docs/CONTRACT.md"
assert_contains "docs/CONTRACT.md" "Network: api_network"
assert_contains "docs/CONTRACT.md" "Containers: api-blue, api-green, redis, nginx"
assert_contains "docs/CONTRACT.md" "Routing: health-based (api-blue, api-green)"
assert_contains "docs/CONTRACT.md" "nginx config: api.conf"
assert_contains "docs/CONTRACT.md" "Redis: redis:6379"
log_ok "Contract documentation present and references required elements"

log_ok "Infra contract checks passed"
