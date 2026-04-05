#!/usr/bin/env bash
# =============================================================================
# scripts/validate-nginx-configs.sh
#
# Validates nginx configuration templates for correctness.
# Ensures maintenance config doesn't have proxy directives.
#
# Usage:
#   bash scripts/validate-nginx-configs.sh
#
# Exit codes:
#   0 — all checks passed
#   1 — validation failures detected
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PASS=0
FAIL=0

log_pass() { echo "[PASS] $*"; PASS=$((PASS + 1)); }
log_fail() { echo "[FAIL] $*"; FAIL=$((FAIL + 1)); }
log_info() { echo "[INFO] $*"; }

# ---------------------------------------------------------------------------
# extract_nginx_location_blocks FILE LOCATION_SPEC
#
# Brace-aware block extractor: outputs the full text of every nginx location
# block whose opening line contains LOCATION_SPEC. Uses brace counting to
# correctly span multi-line blocks with nested braces without cutting off early.
#
# This is the canonical replacement for all `grep -A N 'location'` patterns
# which fail whenever the block has more lines than N, or when grep captures
# text from neighbouring blocks (e.g. the HTTP 301-redirect /health location
# being included alongside the HTTPS proxy_pass /health location).
# ---------------------------------------------------------------------------
extract_nginx_location_blocks() {
  local file="$1"
  local location_spec="$2"
  awk -v spec="${location_spec}" '
    !in_block && index($0, spec) > 0 && /location/ {
      in_block = 1
      depth = 0
      buf = ""
    }
    in_block {
      buf = buf $0 "\n"
      n = split($0, chars, "")
      for (i = 1; i <= n; i++) {
        if (chars[i] == "{") depth++
        else if (chars[i] == "}") {
          depth--
          if (depth == 0) {
            printf "%s", buf
            in_block = 0
            buf = ""
            break
          }
        }
      }
    }
  ' "${file}"
}

cd "${INFRA_DIR}"

# ── Check 1: Maintenance config has no proxy directives ───────────────────────

log_info "Checking maintenance config for proxy directives..."

MAINTENANCE_CONFIG="nginx/api.maintenance.conf"

if [ ! -f "${MAINTENANCE_CONFIG}" ]; then
  log_fail "Maintenance config not found: ${MAINTENANCE_CONFIG}"
else
  if grep -v "^[[:space:]]*#" "${MAINTENANCE_CONFIG}" | grep -q "proxy_pass"; then
    log_fail "Maintenance config contains proxy_pass (CRITICAL: maintenance mode must not proxy)"
  else
    log_pass "Maintenance config has no proxy_pass directives"
  fi
  
  if grep -v "^[[:space:]]*#" "${MAINTENANCE_CONFIG}" | grep -q "upstream"; then
    log_fail "Maintenance config contains upstream blocks (CRITICAL: maintenance mode must not use upstreams)"
  else
    log_pass "Maintenance config has no upstream blocks"
  fi
  
  if grep -v "^[[:space:]]*#" "${MAINTENANCE_CONFIG}" | grep -qE "api-blue|api-green"; then
    log_fail "Maintenance config references backend containers (CRITICAL: maintenance mode must be self-contained)"
  else
    log_pass "Maintenance config has no backend container references"
  fi
fi

# ── Check 2: Maintenance config returns correct status codes ──────────────────

log_info "Checking maintenance config status codes..."

if grep -q 'location = /infra/health' "${MAINTENANCE_CONFIG}"; then
  _infra_blocks="$(extract_nginx_location_blocks "${MAINTENANCE_CONFIG}" 'location = /infra/health')"
  if printf '%s\n' "${_infra_blocks}" | grep -q 'return 200'; then
    log_pass "Maintenance /infra/health returns 200"
  else
    log_fail "Maintenance /infra/health does not return 200"
  fi
else
  log_fail "Maintenance config missing /infra/health location"
fi

if grep -q 'location = /health' "${MAINTENANCE_CONFIG}"; then
  _health_blocks="$(extract_nginx_location_blocks "${MAINTENANCE_CONFIG}" 'location = /health')"
  if printf '%s\n' "${_health_blocks}" | grep -q 'return 503'; then
    log_pass "Maintenance /health returns 503"
  else
    log_fail "Maintenance /health does not return 503 (should signal unhealthy state)"
  fi
else
  log_fail "Maintenance config missing /health location"
fi

if grep -q 'location = /ready' "${MAINTENANCE_CONFIG}"; then
  _ready_blocks="$(extract_nginx_location_blocks "${MAINTENANCE_CONFIG}" 'location = /ready')"
  if printf '%s\n' "${_ready_blocks}" | grep -q 'return 503'; then
    log_pass "Maintenance /ready returns 503"
  else
    log_fail "Maintenance /ready does not return 503"
  fi
else
  log_fail "Maintenance config missing /ready location"
fi

if grep -q 'location / {' "${MAINTENANCE_CONFIG}"; then
  _root_blocks="$(extract_nginx_location_blocks "${MAINTENANCE_CONFIG}" 'location / ')"
  if printf '%s\n' "${_root_blocks}" | grep -q 'return 503'; then
    log_pass "Maintenance / returns 503"
  else
    log_fail "Maintenance / does not return 503"
  fi
else
  log_fail "Maintenance config missing / location"
fi

# ── Check 3: Active config has required endpoints ─────────────────────────────

log_info "Checking active config endpoints..."

ACTIVE_CONFIG="nginx/api.conf"

if [ ! -f "${ACTIVE_CONFIG}" ]; then
  log_fail "Active config not found: ${ACTIVE_CONFIG}"
else
  # Check /infra/health exists and returns 200
  if grep -q 'location = /infra/health' "${ACTIVE_CONFIG}"; then
    log_pass "Active config has /infra/health endpoint"
  else
    log_fail "Active config missing /infra/health endpoint"
  fi

  # Check /health in HTTPS block proxies to backend.
  # Uses brace-aware extraction across all /health blocks, then verifies:
  # (a) At least one block has proxy_pass (the HTTPS block)
  # (b) No block has a 4xx/5xx static return code
  # The HTTP block is allowed to have `return 301` (redirect to HTTPS) —
  # this is intentional and must NOT be flagged as an error.
  _active_health_blocks="$(extract_nginx_location_blocks "${ACTIVE_CONFIG}" 'location = /health')"

  if printf '%s\n' "${_active_health_blocks}" | grep -q 'proxy_pass'; then
    log_pass "Active /health proxies to backend"
  else
    log_fail "Active /health does not proxy to backend"
  fi

  if printf '%s\n' "${_active_health_blocks}" | grep -qE 'return[[:space:]]+[45][0-9][0-9]'; then
    log_fail "Active /health contains a 4xx/5xx static return code (only 301 HTTP redirect is allowed)"
  else
    log_pass "Active /health contains no 4xx/5xx static return codes"
  fi
fi

# ── Check 4: Active config has required placeholders ──────────────────────────

log_info "Checking active config placeholders..."

if [ ! -f "${ACTIVE_CONFIG}" ]; then
  log_fail "Active config not found: ${ACTIVE_CONFIG}"
else
  if grep -q "__API_HOSTNAME__" "${ACTIVE_CONFIG}"; then
    log_pass "Active config has __API_HOSTNAME__ placeholder"
  else
    log_fail "Active config missing __API_HOSTNAME__ placeholder"
  fi
  
  if grep -q "__ACTIVE_CONTAINER__" "${ACTIVE_CONFIG}"; then
    log_pass "Active config has __ACTIVE_CONTAINER__ placeholder"
  else
    log_fail "Active config missing __ACTIVE_CONTAINER__ placeholder"
  fi
fi

# ── Check 5: Both configs have required placeholders ──────────────────────────

log_info "Checking both configs have API_HOSTNAME placeholder..."

for config in "${ACTIVE_CONFIG}" "${MAINTENANCE_CONFIG}"; do
  if [ -f "${config}" ]; then
    if grep -q "__API_HOSTNAME__" "${config}"; then
      log_pass "$(basename ${config}) has __API_HOSTNAME__ placeholder"
    else
      log_fail "$(basename ${config}) missing __API_HOSTNAME__ placeholder"
    fi
  fi
done

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "─────────────────────────────────────"
echo " Nginx Config Validation Summary"
echo "─────────────────────────────────────"
echo " PASS: ${PASS}"
echo " FAIL: ${FAIL}"
echo "─────────────────────────────────────"
echo ""

if [ "$FAIL" -gt 0 ]; then
  echo "Validation failed. Fix the issues above."
  echo ""
  echo "CRITICAL: Maintenance config must NEVER contain:"
  echo "  - proxy_pass directives"
  echo "  - upstream blocks"
  echo "  - references to api-blue or api-green"
  echo ""
  echo "Maintenance mode serves static responses only."
  exit 1
fi

echo "All nginx config validations passed."
exit 0
