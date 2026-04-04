#!/usr/bin/env bash
# =============================================================================
# scripts/validate-docker-cli.sh
#
# Validates that all Docker CLI commands in the repo follow correct patterns.
# Prevents runtime failures due to missing --entrypoint flags.
#
# Usage:
#   bash scripts/validate-docker-cli.sh
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

# ── Check 1: prom/prometheus must use --entrypoint promtool ──────────────────

log_info "Checking prom/prometheus Docker commands..."

if grep -rn "docker run.*prom/prometheus" .github/ scripts/ 2>/dev/null | \
   grep -v "validate-docker-cli.sh" | \
   grep -v "Guard against incorrect Docker CLI usage" | \
   grep -v "\\-\\-entrypoint promtool"; then
  log_fail "Found 'docker run prom/prometheus' without '--entrypoint promtool'"
  echo "       Default entrypoint is 'prometheus', not 'promtool'"
  echo "       Fix: Add '--entrypoint promtool' before image name"
else
  log_pass "All prom/prometheus commands use correct --entrypoint"
fi

# ── Check 2: prom/alertmanager must use --entrypoint amtool ──────────────────

log_info "Checking prom/alertmanager Docker commands..."

if grep -rn "docker run.*prom/alertmanager" .github/ scripts/ 2>/dev/null | \
   grep -v "validate-docker-cli.sh" | \
   grep -v "Guard against incorrect Docker CLI usage" | \
   grep -v "\\-\\-entrypoint amtool"; then
  log_fail "Found 'docker run prom/alertmanager' without '--entrypoint amtool'"
  echo "       Default entrypoint is 'alertmanager', not 'amtool'"
  echo "       Fix: Add '--entrypoint amtool' before image name"
else
  log_pass "All prom/alertmanager commands use correct --entrypoint"
fi

# ── Check 3: All docker run commands use -v and -w correctly ─────────────────

log_info "Checking docker run volume and workdir patterns..."

DOCKER_RUN_LINES=$(grep -rn "docker run" .github/ scripts/ 2>/dev/null | \
                   grep -v "validate-docker-cli.sh" | \
                   grep -v "Guard against incorrect Docker CLI usage" | \
                   grep -v "^Binary" || true)

if echo "${DOCKER_RUN_LINES}" | grep -q "docker run.*prom/"; then
  if echo "${DOCKER_RUN_LINES}" | grep "docker run.*prom/" | grep -qv "\-v.*:/workspace"; then
    log_fail "Found docker run with prom/* image missing '-v \"\${PWD}:/workspace\"'"
  else
    log_pass "All prom/* docker run commands mount /workspace"
  fi
  
  if echo "${DOCKER_RUN_LINES}" | grep "docker run.*prom/" | grep -qv "\-w /workspace"; then
    log_fail "Found docker run with prom/* image missing '-w /workspace'"
  else
    log_pass "All prom/* docker run commands set workdir to /workspace"
  fi
fi

# ── Check 4: All docker run commands use --rm ────────────────────────────────

log_info "Checking docker run cleanup patterns..."

if echo "${DOCKER_RUN_LINES}" | grep "docker run" | grep -v "\\-\\-rm" | grep -qv "docker run -d"; then
  log_fail "Found docker run commands without --rm flag (may leave orphaned containers)"
else
  log_pass "All non-daemon docker run commands use --rm"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "─────────────────────────────────────"
echo " Docker CLI Validation Summary"
echo "─────────────────────────────────────"
echo " PASS: ${PASS}"
echo " FAIL: ${FAIL}"
echo "─────────────────────────────────────"
echo ""

if [ "$FAIL" -gt 0 ]; then
  echo "Validation failed. Fix the issues above before deploying."
  exit 1
fi

echo "All Docker CLI commands follow correct patterns."
exit 0
