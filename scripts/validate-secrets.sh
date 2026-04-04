#!/usr/bin/env bash
# =============================================================================
# scripts/validate-secrets.sh
#
# Validates that all required environment variables and secrets are properly
# configured for the infra deployment.
#
# Usage:
#   bash scripts/validate-secrets.sh [--check-vps]
#
# Options:
#   --check-vps   Also validate .env.monitoring exists on VPS (requires file)
#
# Exit codes:
#   0 — all checks passed
#   1 — validation failures detected
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

CHECK_VPS=false
if [ "${1:-}" = "--check-vps" ]; then
  CHECK_VPS=true
fi

PASS=0
FAIL=0

log_pass() { echo "[PASS] $*"; PASS=$((PASS + 1)); }
log_fail() { echo "[FAIL] $*"; FAIL=$((FAIL + 1)); }
log_info() { echo "[INFO] $*"; }
log_warn() { echo "[WARN] $*"; }

cd "${INFRA_DIR}"

# ── Required Variables ────────────────────────────────────────────────────────

REQUIRED_ENV_VARS=(
  "API_HOSTNAME"
  "GRAFANA_ADMIN_PASSWORD"
  "METRICS_SCRAPE_TOKEN"
  "ALERTMANAGER_SLACK_WEBHOOK"
)

REQUIRED_GITHUB_SECRETS=(
  "VPS_HOST"
  "VPS_USER"
  "VPS_SSH_KEY"
)

OPTIONAL_GITHUB_SECRETS=(
  "VPS_SSH_PORT"
)

# ── Check 1: .env.monitoring.example completeness ─────────────────────────────

log_info "Checking .env.monitoring.example contains all required variables..."

if [ ! -f ".env.monitoring.example" ]; then
  log_fail ".env.monitoring.example not found"
else
  MISSING_VARS=()
  for var in "${REQUIRED_ENV_VARS[@]}"; do
    if ! grep -q "^${var}=" .env.monitoring.example; then
      MISSING_VARS+=("${var}")
    fi
  done
  
  if [ ${#MISSING_VARS[@]} -gt 0 ]; then
    log_fail ".env.monitoring.example missing required variables:"
    printf '       - %s\n' "${MISSING_VARS[@]}"
  else
    log_pass ".env.monitoring.example contains all required variables"
  fi
fi

# ── Check 2: .env.monitoring.example has no real secrets ──────────────────────

log_info "Checking .env.monitoring.example contains no real secrets..."

SUSPICIOUS_PATTERNS=(
  "hooks.slack.com/services/[A-Z0-9]{9,}/[A-Z0-9]{9,}/[A-Za-z0-9]{24,}"
  "[0-9a-f]{32,}"
)

FOUND_SECRETS=false
for pattern in "${SUSPICIOUS_PATTERNS[@]}"; do
  if grep -qE "${pattern}" .env.monitoring.example 2>/dev/null; then
    log_warn "Found pattern matching real secret in .env.monitoring.example"
    FOUND_SECRETS=true
  fi
done

if [ "${FOUND_SECRETS}" = "false" ]; then
  log_pass ".env.monitoring.example contains no real secrets"
fi

# ── Check 3: VPS .env.monitoring validation (if --check-vps) ──────────────────

if [ "${CHECK_VPS}" = "true" ]; then
  log_info "Checking .env.monitoring on VPS..."
  
  if [ ! -f ".env.monitoring" ]; then
    log_fail ".env.monitoring not found (required on VPS)"
  else
    set -a
    # shellcheck source=/dev/null
    source .env.monitoring 2>/dev/null || true
    set +a
    
    MISSING_VPS_VARS=()
    for var in "${REQUIRED_ENV_VARS[@]}"; do
      if [ -z "${!var:-}" ]; then
        MISSING_VPS_VARS+=("${var}")
      fi
    done
    
    if [ ${#MISSING_VPS_VARS[@]} -gt 0 ]; then
      log_fail ".env.monitoring missing or has empty required variables:"
      printf '       - %s\n' "${MISSING_VPS_VARS[@]}"
    else
      log_pass ".env.monitoring contains all required variables"
    fi
    
    # Validate specific formats
    if [ -n "${ALERTMANAGER_SLACK_WEBHOOK:-}" ]; then
      if [[ "${ALERTMANAGER_SLACK_WEBHOOK}" =~ ^https://hooks\.slack\.com/services/ ]]; then
        log_pass "ALERTMANAGER_SLACK_WEBHOOK has valid format"
      else
        log_fail "ALERTMANAGER_SLACK_WEBHOOK does not start with https://hooks.slack.com/services/"
      fi
    fi
    
    if [ -n "${METRICS_SCRAPE_TOKEN:-}" ]; then
      if [ ${#METRICS_SCRAPE_TOKEN} -ge 32 ]; then
        log_pass "METRICS_SCRAPE_TOKEN has sufficient length"
      else
        log_warn "METRICS_SCRAPE_TOKEN is shorter than 32 characters (weak)"
      fi
    fi
    
    if [ -n "${GRAFANA_ADMIN_PASSWORD:-}" ]; then
      if [ ${#GRAFANA_ADMIN_PASSWORD} -ge 12 ]; then
        log_pass "GRAFANA_ADMIN_PASSWORD has sufficient length"
      else
        log_fail "GRAFANA_ADMIN_PASSWORD is shorter than 12 characters (too weak)"
      fi
    fi
  fi
fi

# ── Check 4: Scripts reference correct variables ──────────────────────────────

log_info "Checking scripts reference correct environment variables..."

DEPRECATED_VARS=("FRONTEND_DOMAIN")
FOUND_DEPRECATED=false

for var in "${DEPRECATED_VARS[@]}"; do
  if grep -rq "\${${var}}" scripts/ .github/ 2>/dev/null; then
    log_fail "Found reference to deprecated variable: ${var}"
    FOUND_DEPRECATED=true
  fi
done

if [ "${FOUND_DEPRECATED}" = "false" ]; then
  log_pass "No deprecated variables referenced in scripts"
fi

# ── Check 5: Docker compose files reference correct variables ─────────────────

log_info "Checking docker-compose files reference correct variables..."

COMPOSE_VARS=$(grep -oh '\${[A-Z_]*}' docker-compose.*.yml 2>/dev/null | sort -u | sed 's/[${}]//g')

UNKNOWN_VARS=()
for var in ${COMPOSE_VARS}; do
  KNOWN=false
  for known_var in "${REQUIRED_ENV_VARS[@]}"; do
    if [ "${var}" = "${known_var}" ]; then
      KNOWN=true
      break
    fi
  done
  
  if [ "${KNOWN}" = "false" ]; then
    UNKNOWN_VARS+=("${var}")
  fi
done

if [ ${#UNKNOWN_VARS[@]} -gt 0 ]; then
  log_warn "Found variables in docker-compose files not in required list:"
  printf '       - %s\n' "${UNKNOWN_VARS[@]}"
else
  log_pass "All docker-compose variables are documented"
fi

# ── Check 6: Rendered config files are gitignored ─────────────────────────────

log_info "Checking rendered configs are gitignored..."

RENDERED_FILES=(
  "prometheus/prometheus.rendered.yml"
  "alertmanager/alertmanager.rendered.yml"
)

for file in "${RENDERED_FILES[@]}"; do
  if git check-ignore -q "${file}" 2>/dev/null; then
    log_pass "${file} is gitignored"
  else
    log_fail "${file} is NOT gitignored (may leak secrets)"
  fi
done

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "─────────────────────────────────────"
echo " Secrets Validation Summary"
echo "─────────────────────────────────────"
echo " PASS: ${PASS}"
echo " FAIL: ${FAIL}"
echo "─────────────────────────────────────"
echo ""

if [ "$FAIL" -gt 0 ]; then
  echo "Validation failed. Fix the issues above."
  echo ""
  echo "Required environment variables (.env.monitoring on VPS):"
  printf '  - %s\n' "${REQUIRED_ENV_VARS[@]}"
  echo ""
  echo "Required GitHub secrets (Settings > Secrets and variables > Actions):"
  printf '  - %s\n' "${REQUIRED_GITHUB_SECRETS[@]}"
  echo ""
  echo "Optional GitHub secrets:"
  printf '  - %s\n' "${OPTIONAL_GITHUB_SECRETS[@]}"
  exit 1
fi

echo "All secrets validation checks passed."
exit 0
