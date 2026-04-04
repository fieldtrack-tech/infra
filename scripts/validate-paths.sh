#!/usr/bin/env bash
# =============================================================================
# scripts/validate-paths.sh
#
# Validates that the infra repository is set up with correct paths.
# Checks for canonical path compliance and required directories.
#
# Usage:
#   bash scripts/validate-paths.sh
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

# ── Check 1: Canonical path ───────────────────────────────────────────────────

log_info "Checking infra repository location..."

EXPECTED_INFRA_ROOT="/opt/infra"
if [ "${INFRA_DIR}" = "${EXPECTED_INFRA_ROOT}" ]; then
  log_pass "Infra repository is at canonical path: ${EXPECTED_INFRA_ROOT}"
else
  log_warn "Infra repository is at ${INFRA_DIR} instead of ${EXPECTED_INFRA_ROOT}"
  log_warn "For production VPS, clone to ${EXPECTED_INFRA_ROOT}"
fi

# ── Check 2: Required directories exist ───────────────────────────────────────

log_info "Checking required directories..."

REQUIRED_DIRS=(
  "nginx"
  "nginx/live"
  "nginx/backup"
  "scripts"
  "prometheus"
  "alertmanager"
  "grafana"
  "loki"
  "promtail"
  "blackbox"
  "tempo"
)

for dir in "${REQUIRED_DIRS[@]}"; do
  if [ -d "${INFRA_DIR}/${dir}" ]; then
    log_pass "Directory exists: ${dir}"
  else
    log_fail "Missing directory: ${dir}"
  fi
done

# ── Check 3: Required files exist ─────────────────────────────────────────────

log_info "Checking required files..."

REQUIRED_FILES=(
  "nginx/api.conf"
  "nginx/api.maintenance.conf"
  "docker-compose.nginx.yml"
  "docker-compose.redis.yml"
  "docker-compose.monitoring.yml"
  "scripts/bootstrap.sh"
  "scripts/nginx-sync.sh"
  "scripts/monitoring-sync.sh"
  "scripts/render-prometheus.sh"
  "scripts/render-alertmanager.sh"
  ".env.monitoring.example"
)

for file in "${REQUIRED_FILES[@]}"; do
  if [ -f "${INFRA_DIR}/${file}" ]; then
    log_pass "File exists: ${file}"
  else
    log_fail "Missing file: ${file}"
  fi
done

# ── Check 4: Scripts are executable ───────────────────────────────────────────

log_info "Checking script permissions..."

SCRIPTS=(
  "scripts/bootstrap.sh"
  "scripts/nginx-sync.sh"
  "scripts/monitoring-sync.sh"
  "scripts/render-prometheus.sh"
  "scripts/render-alertmanager.sh"
  "scripts/check-contract.sh"
  "scripts/verify-alertmanager.sh"
)

for script in "${SCRIPTS[@]}"; do
  if [ -x "${INFRA_DIR}/${script}" ]; then
    log_pass "Script is executable: ${script}"
  else
    log_warn "Script is not executable: ${script} (run: chmod +x ${script})"
  fi
done

# ── Check 5: No hardcoded home paths ──────────────────────────────────────────

log_info "Checking for hardcoded home paths..."

if grep -r "/home/ashish" "${INFRA_DIR}/scripts" 2>/dev/null | grep -v "validate-paths.sh" | grep -q .; then
  log_fail "Found hardcoded /home/ashish paths in scripts"
else
  log_pass "No hardcoded /home/ashish paths found"
fi

if grep -r "~/infra" "${INFRA_DIR}/scripts" 2>/dev/null | grep -v "validate-paths.sh" | grep -q .; then
  log_fail "Found hardcoded ~/infra paths in scripts"
else
  log_pass "No hardcoded ~/infra paths found in scripts"
fi

# ── Check 6: Docker compose files use relative paths ──────────────────────────

log_info "Checking docker-compose files..."

COMPOSE_FILES=(
  "docker-compose.nginx.yml"
  "docker-compose.redis.yml"
  "docker-compose.monitoring.yml"
)

for compose_file in "${COMPOSE_FILES[@]}"; do
  if [ -f "${INFRA_DIR}/${compose_file}" ]; then
    if grep -q "^\s*-\s*\." "${INFRA_DIR}/${compose_file}"; then
      log_pass "${compose_file} uses relative paths"
    else
      log_warn "${compose_file} may not use relative paths"
    fi
  fi
done

# ── Check 7: State directory ──────────────────────────────────────────────────

log_info "Checking state directory..."

STATE_DIR="/var/lib/fieldtrack"
if [ -d "${STATE_DIR}" ]; then
  log_pass "State directory exists: ${STATE_DIR}"
  if [ -w "${STATE_DIR}" ]; then
    log_pass "State directory is writable"
  else
    log_warn "State directory is not writable (may need sudo)"
  fi
else
  log_warn "State directory does not exist: ${STATE_DIR} (will be created by bootstrap)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "─────────────────────────────────────"
echo " Path Validation Summary"
echo "─────────────────────────────────────"
echo " PASS: ${PASS}"
echo " WARN: ${WARN}"
echo " FAIL: ${FAIL}"
echo "─────────────────────────────────────"
echo ""

if [ "$FAIL" -gt 0 ]; then
  echo "Validation failed. Fix the issues above."
  exit 1
fi

if [ "$WARN" -gt 0 ]; then
  echo "Validation passed with warnings."
  echo "Review warnings above for production deployment."
fi

if [ "${INFRA_DIR}" != "${EXPECTED_INFRA_ROOT}" ]; then
  echo ""
  echo "NOTE: For production VPS, ensure infra is cloned to ${EXPECTED_INFRA_ROOT}"
  echo "      Current location: ${INFRA_DIR}"
fi

echo "Path validation complete."
exit 0
