#!/usr/bin/env bash
# =============================================================================
# scripts/validate-system.sh
#
# Comprehensive system validation for FieldTrack infra.
# Validates all components are correctly configured and operational.
#
# Usage:
#   bash scripts/validate-system.sh
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
WARN=0

log_pass() { echo "[PASS] $*"; PASS=$((PASS + 1)); }
log_fail() { echo "[FAIL] $*"; FAIL=$((FAIL + 1)); }
log_warn() { echo "[WARN] $*"; WARN=$((WARN + 1)); }
log_info() { echo "[INFO] $*"; }

# ── Check 1: Path validation ──────────────────────────────────────────────────

log_info "Running path validation..."
if bash "${SCRIPT_DIR}/validate-paths.sh" >/dev/null 2>&1; then
  log_pass "Path validation passed"
else
  log_fail "Path validation failed"
fi

# ── Check 2: Nginx config validation ──────────────────────────────────────────

log_info "Running nginx config validation..."
if bash "${SCRIPT_DIR}/validate-nginx-configs.sh" >/dev/null 2>&1; then
  log_pass "Nginx config validation passed"
else
  log_fail "Nginx config validation failed"
fi

# ── Check 3: Docker CLI validation ────────────────────────────────────────────

log_info "Running Docker CLI validation..."
if bash "${SCRIPT_DIR}/validate-docker-cli.sh" >/dev/null 2>&1; then
  log_pass "Docker CLI validation passed"
else
  log_fail "Docker CLI validation failed"
fi

# ── Check 4: Secrets validation ───────────────────────────────────────────────

log_info "Running secrets validation..."
if bash "${SCRIPT_DIR}/validate-secrets.sh" >/dev/null 2>&1; then
  log_pass "Secrets validation passed"
else
  log_fail "Secrets validation failed"
fi

# ── Check 5: State directory ──────────────────────────────────────────────────

log_info "Checking state directory..."

STATE_DIR="/var/lib/fieldtrack"
if [ -d "${STATE_DIR}" ]; then
  log_pass "State directory exists: ${STATE_DIR}"
  
  if [ -f "${STATE_DIR}/active-slot" ]; then
    SLOT_VALUE="$(cat "${STATE_DIR}/active-slot" 2>/dev/null | tr -d '[:space:]')"
    if [ "${SLOT_VALUE}" = "blue" ] || [ "${SLOT_VALUE}" = "green" ]; then
      log_pass "Active slot file is valid: ${SLOT_VALUE}"
    else
      log_fail "Active slot file has invalid value: ${SLOT_VALUE}"
    fi
  else
    log_warn "Active slot file does not exist (will be created by bootstrap)"
  fi
else
  log_warn "State directory does not exist (will be created by bootstrap)"
fi

# ── Check 6: Docker network ───────────────────────────────────────────────────

log_info "Checking Docker network..."

if docker network ls --format '{{.Name}}' | grep -qx 'api_network'; then
  log_pass "Docker network 'api_network' exists"
else
  log_warn "Docker network 'api_network' does not exist (will be created by bootstrap)"
fi

# ── Check 7: Docker containers ────────────────────────────────────────────────

log_info "Checking Docker containers..."

if docker ps --format '{{.Names}}' | grep -qx 'nginx'; then
  log_pass "nginx container is running"
else
  log_warn "nginx container is not running"
fi

if docker ps --format '{{.Names}}' | grep -qx 'redis'; then
  log_pass "redis container is running"
else
  log_warn "redis container is not running"
fi

# ── Check 8: Nginx config files ───────────────────────────────────────────────

log_info "Checking nginx config files..."

if [ -f "${INFRA_DIR}/nginx/live/api.conf" ]; then
  log_pass "Live nginx config exists"
  
  # Check if it's maintenance or active
  if grep -q "return 503" "${INFRA_DIR}/nginx/live/api.conf"; then
    log_info "Current mode: maintenance"
  elif grep -q "proxy_pass" "${INFRA_DIR}/nginx/live/api.conf"; then
    log_info "Current mode: active"
  else
    log_warn "Cannot determine current nginx mode"
  fi
else
  log_warn "Live nginx config does not exist (will be created by nginx-sync)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "─────────────────────────────────────"
echo " System Validation Summary"
echo "─────────────────────────────────────"
echo " PASS: ${PASS}"
echo " WARN: ${WARN}"
echo " FAIL: ${FAIL}"
echo "─────────────────────────────────────"
echo ""

if [ "$FAIL" -gt 0 ]; then
  echo "System validation failed. Fix the issues above."
  exit 1
fi

if [ "$WARN" -gt 0 ]; then
  echo "System validation passed with warnings."
  echo "Warnings are expected on a fresh system before bootstrap."
fi

echo "System validation complete."
exit 0
