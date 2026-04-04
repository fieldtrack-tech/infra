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

if grep -q 'location = /health' "${MAINTENANCE_CONFIG}"; then
  if grep -A 3 'location = /health' "${MAINTENANCE_CONFIG}" | grep -q 'return 200'; then
    log_pass "Maintenance /health returns 200"
  else
    log_fail "Maintenance /health does not return 200"
  fi
else
  log_fail "Maintenance config missing /health location"
fi

if grep -q 'location = /ready' "${MAINTENANCE_CONFIG}"; then
  if grep -A 3 'location = /ready' "${MAINTENANCE_CONFIG}" | grep -q 'return 503'; then
    log_pass "Maintenance /ready returns 503"
  else
    log_fail "Maintenance /ready does not return 503"
  fi
else
  log_fail "Maintenance config missing /ready location"
fi

if grep -q 'location / {' "${MAINTENANCE_CONFIG}"; then
  if grep -A 3 'location / {' "${MAINTENANCE_CONFIG}" | grep -q 'return 503'; then
    log_pass "Maintenance / returns 503"
  else
    log_fail "Maintenance / does not return 503"
  fi
else
  log_fail "Maintenance config missing / location"
fi

# ── Check 3: Active config has required placeholders ──────────────────────────

log_info "Checking active config placeholders..."

ACTIVE_CONFIG="nginx/api.conf"

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

# ── Check 4: Both configs have required placeholders ──────────────────────────

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
