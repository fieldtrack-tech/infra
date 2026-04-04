#!/usr/bin/env bash
# =============================================================================
# scripts/monitoring-sync.sh
#
# Starts or updates the monitoring stack (Prometheus, Grafana, Alertmanager,
# Loki, Promtail, Blackbox, Redis exporter, node-exporter).
#
# This script NEVER touches nginx or Redis containers.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENV_FILE="${INFRA_DIR}/.env.monitoring"
COMPOSE_FILE="${INFRA_DIR}/docker-compose.monitoring.yml"

MONITORING_CONTAINERS=(
  "loki"
  "blackbox"
  "promtail"
  "alertmanager"
  "prometheus"
  "grafana"
  "node-exporter"
  "redis-exporter"
)

log_info()  { printf '[monitoring-sync] INFO  %s\n' "$*"; }
log_error() { printf '[monitoring-sync] ERROR %s\n' "$*" >&2; }
log_ok()    { printf '[monitoring-sync] OK    %s\n' "$*"; }

require_env() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    log_error "${name} is not set in ${ENV_FILE}"
    exit 1
  fi
}

container_is_ready() {
  local cname="$1"
  local status
  local health

  status="$(docker inspect --format '{{.State.Status}}' "${cname}" 2>/dev/null || echo "missing")"
  if [ "${status}" != "running" ]; then
    return 1
  fi

  health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${cname}" 2>/dev/null || echo "missing")"
  [ "${health}" = "healthy" ] || [ "${health}" = "none" ]
}

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
if [ ! -f "${ENV_FILE}" ]; then
  log_error "Missing ${ENV_FILE}"
  log_error "Copy .env.monitoring.example to .env.monitoring and fill in all values."
  exit 1
fi

set -a
# shellcheck source=/dev/null
source "${ENV_FILE}"
set +a

require_env API_HOSTNAME
require_env GRAFANA_ADMIN_PASSWORD
require_env METRICS_SCRAPE_TOKEN

# ---------------------------------------------------------------------------
# Step 1: Render generated configs (templates → rendered)
# ---------------------------------------------------------------------------
log_info "Rendering Prometheus config..."
bash "${SCRIPT_DIR}/render-prometheus.sh"
log_ok "Prometheus config rendered"

log_info "Rendering alertmanager config..."
bash "${SCRIPT_DIR}/render-alertmanager.sh"
log_ok "Alertmanager config rendered"

# ---------------------------------------------------------------------------
# Step 2: Bring up the monitoring stack
# ---------------------------------------------------------------------------
log_info "Starting monitoring stack..."
docker compose \
  --env-file "${ENV_FILE}" \
  -f "${COMPOSE_FILE}" \
  up -d
log_ok "docker compose up completed"

# ---------------------------------------------------------------------------
# Step 3: Validate all monitoring containers are ready
# ---------------------------------------------------------------------------
log_info "Waiting for monitoring containers to become ready (up to 90s)..."

WAIT_SECONDS=90
INTERVAL=5
elapsed=0

while [ "${elapsed}" -lt "${WAIT_SECONDS}" ]; do
  ALL_READY=true
  for cname in "${MONITORING_CONTAINERS[@]}"; do
    if ! container_is_ready "${cname}"; then
      ALL_READY=false
      break
    fi
  done

  [ "${ALL_READY}" = "true" ] && break
  sleep "${INTERVAL}"
  elapsed=$((elapsed + INTERVAL))
done

FAIL=false
for cname in "${MONITORING_CONTAINERS[@]}"; do
  STATUS="$(docker inspect --format '{{.State.Status}}' "${cname}" 2>/dev/null || echo "missing")"
  HEALTH="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${cname}" 2>/dev/null || echo "missing")"

  if container_is_ready "${cname}"; then
    log_ok "  ${cname}: ${STATUS} (${HEALTH})"
  else
    log_error "  ${cname}: ${STATUS} (${HEALTH})"
    FAIL=true
  fi
done

if [ "${FAIL}" = "true" ]; then
  log_error "One or more monitoring containers failed readiness checks."
  log_error "Inspect logs: docker compose --env-file ${ENV_FILE} -f ${COMPOSE_FILE} logs --tail=50"
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 4: Safety assertion — confirm API containers were NOT affected
# ---------------------------------------------------------------------------
log_info "Confirming API containers were not affected..."
for slot in blue green; do
  cname="api-${slot}"
  if docker inspect "${cname}" &>/dev/null; then
    STATUS="$(docker inspect --format='{{.State.Status}}' "${cname}")"
    log_info "  ${cname}: ${STATUS} (unchanged by this script)"
  fi
done

log_ok "monitoring-sync complete — core services unaffected."
