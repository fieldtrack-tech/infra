#!/usr/bin/env bash
# =============================================================================
# scripts/bootstrap.sh
#
# First-time VPS setup for FieldTrack core infra.
# Creates api_network, starts Redis, validates it, and starts nginx safely.
#
# CANONICAL PATH: /opt/infra
# This script expects to be run from the infra repository root.
#
# Usage:
#   bash scripts/bootstrap.sh [--with-monitoring]
#
# Options:
#   --with-monitoring   Also start the monitoring stack after core services
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Validate we're running from the expected location
EXPECTED_INFRA_ROOT="/opt/infra"
if [ "${INFRA_DIR}" != "${EXPECTED_INFRA_ROOT}" ]; then
  echo "[bootstrap] WARN  Running from ${INFRA_DIR} instead of ${EXPECTED_INFRA_ROOT}"
  echo "[bootstrap] WARN  For production, infra should be cloned to ${EXPECTED_INFRA_ROOT}"
fi
STATE_DIR="/var/lib/fieldtrack"
ACTIVE_SLOT_FILE="${STATE_DIR}/active-slot"

WITH_MONITORING=false
for arg in "$@"; do
  case "$arg" in
    --with-monitoring) WITH_MONITORING=true ;;
    *) echo "[bootstrap] ERROR Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

log_info()  { printf '[bootstrap] INFO  %s\n' "$*"; }
log_warn()  { printf '[bootstrap] WARN  %s\n' "$*" >&2; }
log_error() { printf '[bootstrap] ERROR %s\n' "$*" >&2; }
log_ok()    { printf '[bootstrap] OK    %s\n' "$*"; }

install_nginx_watchdog() {
  local watchdog_tag="fieldtrack-nginx-watchdog"
  local cron_line
  local existing_cron

  cron_line="* * * * * API_HOSTNAME='${API_HOSTNAME}' bash -lc 'cd \"${INFRA_DIR}\" && if [ -f .env.monitoring ]; then set -a; . ./.env.monitoring; set +a; fi; bash \"${SCRIPT_DIR}/nginx-sync.sh\"' >> \"${INFRA_DIR}/nginx-sync-watchdog.log\" 2>&1 # ${watchdog_tag}"
  existing_cron="$(crontab -l 2>/dev/null || true)"

  if printf '%s\n' "${existing_cron}" | grep -Fq "${watchdog_tag}"; then
    log_ok "nginx watchdog cron already installed"
    return 0
  fi

  {
    printf '%s\n' "${existing_cron}" | sed '/^[[:space:]]*$/d'
    printf '%s\n' "${cron_line}"
  } | crontab -

  log_ok "nginx watchdog cron installed"
}

wait_for_redis() {
  local attempt

  log_info "Waiting for Redis readiness..."
  # shellcheck disable=SC2034
  for attempt in $(seq 1 30); do
    if docker exec redis redis-cli ping 2>/dev/null | grep -q '^PONG$'; then
      log_ok "Redis ready"
      return 0
    fi
    sleep 1
  done

  log_error "Redis not ready after 30 seconds."
  return 1
}

validate_redis_network() {
  log_info "Validating Redis reachability on api_network..."
  if docker run --rm --network api_network redis:7-alpine redis-cli -h redis ping 2>/dev/null | grep -q '^PONG$'; then
    log_ok "Redis network probe succeeded"
    return 0
  fi

  log_error "Redis network probe failed."
  return 1
}

wait_for_nginx() {
  local attempt

  log_info "Waiting for nginx liveness..."
  # shellcheck disable=SC2034
  for attempt in $(seq 1 30); do
    if docker exec nginx sh -eu -c "wget -q --spider --timeout=5 --tries=1 http://127.0.0.1/health" >/dev/null 2>&1; then
      log_ok "nginx ready"
      return 0
    fi
    sleep 1
  done

  log_error "nginx did not become healthy after 30 seconds."
  return 1
}

resolve_bootstrap_slot() {
  if [ -f "${ACTIVE_SLOT_FILE}" ]; then
    case "$(tr -d '[:space:]' < "${ACTIVE_SLOT_FILE}")" in
      blue|green)
        tr -d '[:space:]' < "${ACTIVE_SLOT_FILE}"
        return 0
        ;;
    esac
  fi

  printf 'blue'
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
if ! command -v docker &>/dev/null; then
  log_error "Docker not found. Install Docker CE first."
  exit 1
fi

if ! docker compose version &>/dev/null 2>&1; then
  log_error "Docker Compose v2 plugin not found. Install it first."
  exit 1
fi

if ! command -v curl &>/dev/null; then
  log_error "curl not found. Install it before running bootstrap."
  exit 1
fi

if ! command -v crontab &>/dev/null; then
  log_error "crontab not found. Install cron before running bootstrap so nginx failover remains protected."
  exit 1
fi

if [ -z "${API_HOSTNAME:-}" ]; then
  log_error "API_HOSTNAME is not set."
  log_error "Export it before running: export API_HOSTNAME=api.example.com"
  exit 1
fi

if [ ! -f /etc/ssl/api/origin.crt ] || [ ! -f /etc/ssl/api/origin.key ]; then
  log_error "TLS files are missing."
  log_error "Expected /etc/ssl/api/origin.crt and /etc/ssl/api/origin.key"
  exit 1
fi

mkdir -p "${STATE_DIR}" /var/www/certbot /var/log/nginx

# ---------------------------------------------------------------------------
# 1. Create shared Docker network
# ---------------------------------------------------------------------------
log_info "Ensuring api_network exists..."
if docker network ls --format '{{.Name}}' | grep -qx 'api_network'; then
  log_ok "api_network already exists"
else
  docker network create api_network >/dev/null
  log_ok "api_network created"
fi

# ---------------------------------------------------------------------------
# 2. Start and validate Redis
# ---------------------------------------------------------------------------
log_info "Starting Redis..."
docker compose \
  -f "${INFRA_DIR}/docker-compose.redis.yml" \
  up -d redis >/dev/null
log_ok "Redis container started"

wait_for_redis
validate_redis_network

# ---------------------------------------------------------------------------
# 3. Render nginx config safely
# ---------------------------------------------------------------------------
BOOTSTRAP_SLOT="$(resolve_bootstrap_slot)"
log_info "Syncing nginx using slot '${BOOTSTRAP_SLOT}'..."

if ! bash "${SCRIPT_DIR}/nginx-sync.sh" --active-slot "${BOOTSTRAP_SLOT}"; then
  log_error "nginx sync failed during bootstrap."
  exit 1
fi
log_ok "nginx sync completed"

wait_for_nginx
log_info "Validating host-level nginx /health endpoint..."
if curl -sf http://localhost/health >/dev/null; then
  log_ok "Host-level /health probe passed"
else
  log_error "Host-level /health probe failed."
  exit 1
fi

install_nginx_watchdog

# ---------------------------------------------------------------------------
# 4. (Optional) Start monitoring stack without blocking core infra
# ---------------------------------------------------------------------------
MONITORING_FAILED=false
if [ "${WITH_MONITORING}" = "true" ]; then
  log_info "Starting monitoring stack..."
  if bash "${SCRIPT_DIR}/monitoring-sync.sh"; then
    log_ok "Monitoring stack started"
  else
    MONITORING_FAILED=true
    log_warn "Monitoring failed to start. Core infra is still healthy."
  fi
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
log_ok "Bootstrap complete."
log_info "  api_network : ready"
log_info "  Redis       : ready and reachable on api_network"
log_info "  nginx       : ready"

if [ "${WITH_MONITORING}" = "false" ]; then
  log_info ""
  log_info "Monitoring was NOT started. To start it later:"
  log_info "  bash scripts/monitoring-sync.sh"
fi

if [ "${MONITORING_FAILED}" = "true" ]; then
  log_warn "Monitoring is optional and remains down. Review scripts/monitoring-sync.sh output."
fi

log_info ""
log_info "On a fresh VPS, nginx may start in maintenance mode until the first healthy API slot is deployed."
log_info "You can now run the first API deployment from the API repo:"
log_info "  ./scripts/deploy.sh <image-sha>"
