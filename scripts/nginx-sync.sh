#!/usr/bin/env bash
# =============================================================================
# scripts/nginx-sync.sh
#
# Safely renders the nginx config and only switches traffic when the API
# backend container is alive on api_network.
#
# CANONICAL PATH: /opt/infra
# This script expects to be run from the infra repository root.
#
# Usage:
#   bash scripts/nginx-sync.sh
#   API_BACKEND_CONTAINER=api bash scripts/nginx-sync.sh
#   bash scripts/nginx-sync.sh --allow-missing-backend
#
# Options:
#   --allow-missing-backend        Kept for backward compatibility; maintenance
#                                  mode is used automatically when no healthy
#                                  backend exists
#
# Required environment:
#   API_HOSTNAME   Public hostname served by nginx (no scheme, no slash)
#
# Optional environment:
#   API_BACKEND_CONTAINER   Docker container name on api_network (default: api)
#   EXPECTED_DEPLOY_SHA     When set, backend image labels must match
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Validate we're running from the expected location
EXPECTED_INFRA_ROOT="/opt/infra"
if [ "${INFRA_DIR}" != "${EXPECTED_INFRA_ROOT}" ]; then
  echo "[nginx-sync] WARN  Running from ${INFRA_DIR} instead of ${EXPECTED_INFRA_ROOT}" >&2
  echo "[nginx-sync] WARN  For production, infra should be cloned to ${EXPECTED_INFRA_ROOT}" >&2
fi

TEMPLATE_FILE="${INFRA_DIR}/nginx/api.conf"
MAINTENANCE_TEMPLATE_FILE="${INFRA_DIR}/nginx/api.maintenance.conf"
LIVE_DIR="${INFRA_DIR}/nginx/live"
BACKUP_DIR="${INFRA_DIR}/nginx/backup"
OUTPUT_FILE="${LIVE_DIR}/api.conf"
NGINX_COMPOSE_FILE="${INFRA_DIR}/docker-compose.nginx.yml"

log_info()  { printf '[nginx-sync] INFO  %s\n' "$*"; }
log_warn()  { printf '[nginx-sync] WARN  %s\n' "$*" >&2; }
log_error() { printf '[nginx-sync] ERROR %s\n' "$*" >&2; }
log_ok()    { printf '[nginx-sync] OK    %s\n' "$*"; }

ALLOW_MISSING_BACKEND=false
SELECTED_CONTAINER=""
CONTAINER_SOURCE="unknown"
ROUTING_MODE="active"
EXPECTED_DEPLOY_SHA="${EXPECTED_DEPLOY_SHA:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --allow-missing-backend)
      ALLOW_MISSING_BACKEND=true
      shift
      ;;
    *)
      log_error "Unknown argument: $1"
      exit 1
      ;;
  esac
done

if [ -z "${API_HOSTNAME:-}" ]; then
  log_error "API_HOSTNAME is not set."
  log_error "Export it before running: export API_HOSTNAME=api.example.com"
  exit 1
fi

escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[\\/&]/\\&/g'
}

backend_name_valid() {
  [[ "${1:-}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] && [ "${#1}" -le 128 ]
}

read_backend_from_live_config() {
  if [ ! -f "${OUTPUT_FILE}" ]; then
    return 0
  fi

  grep -oE 'set \$api_backend "http://[a-zA-Z0-9_.-]+:3000"' "${OUTPUT_FILE}" 2>/dev/null \
    | head -1 \
    | sed -n 's/.*http:\/\/\([a-zA-Z0-9_.-]*\):3000.*/\1/p'
}

resolve_backend_container() {
  local candidate=""

  if [ -n "${API_BACKEND_CONTAINER:-}" ]; then
    if backend_name_valid "${API_BACKEND_CONTAINER}"; then
      SELECTED_CONTAINER="${API_BACKEND_CONTAINER}"
      CONTAINER_SOURCE="env"
      log_info "Backend container (from API_BACKEND_CONTAINER): ${SELECTED_CONTAINER}"
      return 0
    fi
    log_warn "Invalid API_BACKEND_CONTAINER '${API_BACKEND_CONTAINER}'. Ignoring."
  fi

  candidate="$(read_backend_from_live_config)"
  if [ -n "${candidate}" ] && backend_name_valid "${candidate}"; then
    SELECTED_CONTAINER="${candidate}"
    CONTAINER_SOURCE="live-config"
    log_info "Backend container (from live nginx config): ${SELECTED_CONTAINER}"
    return 0
  fi

  SELECTED_CONTAINER="api"
  CONTAINER_SOURCE="default"
  log_info "Backend container (default): ${SELECTED_CONTAINER}"
}

render_template() {
  local template_file="$1"
  local destination_file="$2"
  local escaped_hostname
  local escaped_container

  escaped_hostname="$(escape_sed_replacement "${API_HOSTNAME}")"
  escaped_container="$(escape_sed_replacement "${SELECTED_CONTAINER}")"

  sed \
    -e "s/__API_HOSTNAME__/${escaped_hostname}/g" \
    -e "s/__ACTIVE_CONTAINER__/${escaped_container}/g" \
    "${template_file}" > "${destination_file}"
}

backend_exists() {
  local container_name="$1"
  docker inspect "${container_name}" >/dev/null 2>&1
}

backend_running() {
  local container_name="$1"
  [ "$(docker inspect --format '{{.State.Status}}' "${container_name}" 2>/dev/null || true)" = "running" ]
}

backend_attached_to_network() {
  local container_name="$1"
  [ "$(docker inspect --format '{{if index .NetworkSettings.Networks "api_network"}}yes{{else}}no{{end}}' "${container_name}" 2>/dev/null || true)" = "yes" ]
}

backend_matches_expected_sha() {
  local container_name="$1"
  local revision_label
  local deploy_label

  if [ -z "${EXPECTED_DEPLOY_SHA}" ]; then
    return 0
  fi

  revision_label="$(docker inspect --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "${container_name}" 2>/dev/null || true)"
  deploy_label="$(docker inspect --format '{{ index .Config.Labels "com.fieldtrack.deploy-sha" }}' "${container_name}" 2>/dev/null || true)"

  if [ "${revision_label}" = "${EXPECTED_DEPLOY_SHA}" ] || [ "${deploy_label}" = "${EXPECTED_DEPLOY_SHA}" ]; then
    return 0
  fi

  log_info "Container ${container_name} did not match EXPECTED_DEPLOY_SHA='${EXPECTED_DEPLOY_SHA}'"
  return 1
}

validate_candidate_config() {
  local candidate_dir="$1"

  docker run --rm \
    -v "${candidate_dir}:/etc/nginx/conf.d:ro" \
    -v /etc/ssl/api:/etc/ssl/api:ro \
    -v /var/www/certbot:/var/www/certbot:ro \
    -v /var/log/nginx:/var/log/nginx \
    nginx:1.25-alpine \
    nginx -t >/dev/null
}

probe_backend_direct() {
  local container_name="$1"
  docker run --rm \
    --network api_network \
    --entrypoint sh \
    nginx:1.25-alpine \
    -eu -c "wget -q --spider --timeout=5 --tries=1 http://${container_name}:3000/health"
}

wait_for_nginx_running() {
  local attempt
  local status

  # shellcheck disable=SC2034
  for attempt in $(seq 1 30); do
    status="$(docker inspect --format '{{.State.Status}}' nginx 2>/dev/null || true)"
    if [ "${status}" = "running" ]; then
      return 0
    fi
    sleep 1
  done

  return 1
}

probe_nginx_liveness() {
  # Use /infra/health for nginx liveness (never depends on backend)
  docker exec nginx sh -eu -c \
    "wget -q --spider --timeout=5 --tries=1 http://127.0.0.1/infra/health"
}

probe_route_through_nginx() {
  docker exec nginx sh -eu -c \
    "wget -q --spider --timeout=5 --tries=1 --no-check-certificate --header='Host: ${API_HOSTNAME}' https://127.0.0.1/health"
}

probe_ready_through_nginx() {
  docker exec nginx sh -eu -c \
    "wget -q --spider --timeout=5 --tries=1 --no-check-certificate --header='Host: ${API_HOSTNAME}' https://127.0.0.1/ready"
}

run_probe_with_retries() {
  local description="$1"
  shift
  local attempt

  for attempt in 1 2 3; do
    if "$@"; then
      return 0
    fi

    if [ "${attempt}" -lt 3 ]; then
      log_info "${description} failed on attempt ${attempt}; retrying..."
      sleep 1
    fi
  done

  return 1
}

backend_is_usable() {
  local container_name="$1"

  if ! backend_exists "${container_name}"; then
    return 1
  fi

  if ! backend_running "${container_name}"; then
    return 1
  fi

  if ! backend_attached_to_network "${container_name}"; then
    return 1
  fi

  if ! backend_matches_expected_sha "${container_name}"; then
    return 1
  fi

  run_probe_with_retries "Direct backend probe for ${container_name}" probe_backend_direct "${container_name}"
}

rollback_live_config() {
  if [ -n "${BACKUP_FILE:-}" ] && [ -f "${BACKUP_FILE}" ]; then
    cp "${BACKUP_FILE}" "${OUTPUT_FILE}"
    if docker inspect nginx >/dev/null 2>&1; then
      docker exec nginx nginx -s reload >/dev/null 2>&1 || true
    fi
    log_info "Rolled back to ${BACKUP_FILE}"
  else
    rm -f "${OUTPUT_FILE}"
    docker compose -f "${NGINX_COMPOSE_FILE}" stop nginx >/dev/null 2>&1 || true
    log_info "Removed candidate config and stopped nginx (no backup was available)"
  fi

  log_error "=== ROLLBACK DEBUGGING INFO ==="
  log_error "Backend container: ${SELECTED_CONTAINER:-unknown}"
  log_error "Routing mode: ${ROUTING_MODE:-unknown}"
  log_error "Rendered config: ${OUTPUT_FILE}"
  if [ -f "${OUTPUT_FILE}" ]; then
    log_error "Config preview (first 20 lines):"
    head -20 "${OUTPUT_FILE}" | sed 's/^/  /' >&2
  fi
  log_error "Nginx error log (last 20 lines):"
  docker exec nginx cat /var/log/nginx/api_error.log 2>/dev/null | tail -20 | sed 's/^/  /' >&2 || log_error "Could not read nginx error log"
  log_error "=== END DEBUGGING INFO ==="
}

mkdir -p "${LIVE_DIR}" "${BACKUP_DIR}"

resolve_backend_container

TARGET_TEMPLATE="${TEMPLATE_FILE}"
ROUTING_MODE="active"

if backend_is_usable "${SELECTED_CONTAINER}"; then
  :
else
  ROUTING_MODE="maintenance"
  TARGET_TEMPLATE="${MAINTENANCE_TEMPLATE_FILE}"
  if [ "${ALLOW_MISSING_BACKEND}" = "true" ]; then
    log_info "No healthy backend was found — rendering maintenance config instead"
  else
    log_warn "No healthy backend was found — switching nginx to maintenance mode"
  fi
fi

TEMP_CONF_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "${TEMP_CONF_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

render_template "${TARGET_TEMPLATE}" "${TEMP_CONF_DIR}/api.conf"

# CRITICAL: Validate config matches expected mode
log_info "Validating rendered config matches mode: ${ROUTING_MODE}"
if [ "${ROUTING_MODE}" = "maintenance" ]; then
  # Maintenance mode MUST NOT have proxy directives
  if grep -v "^[[:space:]]*#" "${TEMP_CONF_DIR}/api.conf" | grep -qE "proxy_pass|upstream|api-blue|api-green|set \\\$api_backend"; then
    log_error "CRITICAL: Maintenance config contains proxy directives or backend references"
    log_error "This will cause 502 errors. Config validation failed."
    grep -n "proxy_pass\|upstream\|api-blue\|api-green\|set \\\$api_backend" "${TEMP_CONF_DIR}/api.conf" || true
    exit 1
  fi
  log_ok "Maintenance config validated: no proxy directives"

  # Verify maintenance config returns 503 for /health
  if ! grep -A 2 'location = /health' "${TEMP_CONF_DIR}/api.conf" | grep -q "return 503"; then
    log_error "CRITICAL: Maintenance /health does not return 503"
    log_error "Maintenance mode MUST return 503 for /health to signal unhealthy state"
    exit 1
  fi
  log_ok "Maintenance config validated: /health returns 503"

  # Verify /infra/health exists
  if ! grep -q 'location = /infra/health' "${TEMP_CONF_DIR}/api.conf"; then
    log_error "CRITICAL: Maintenance config missing /infra/health endpoint"
    exit 1
  fi
  log_ok "Maintenance config validated: /infra/health exists"
else
  # Active mode MUST have upstream or proxy_pass
  if ! grep -v "^[[:space:]]*#" "${TEMP_CONF_DIR}/api.conf" | grep -qE "proxy_pass|upstream"; then
    log_error "CRITICAL: Active config missing proxy directives"
    exit 1
  fi
  log_ok "Active config validated: has proxy directives"

  # Verify active /health proxies to backend (MUST NOT have "return" in /health block)
  if grep -A 5 'location = /health' "${TEMP_CONF_DIR}/api.conf" | grep -q "return [0-9]"; then
    log_error "CRITICAL: Active /health contains static return statement"
    log_error "Active mode MUST proxy /health to backend, not return static response"
    exit 1
  fi
  log_ok "Active config validated: /health proxies to backend"

  # Verify /infra/health exists
  if ! grep -q 'location = /infra/health' "${TEMP_CONF_DIR}/api.conf"; then
    log_error "CRITICAL: Active config missing /infra/health endpoint"
    exit 1
  fi
  log_ok "Active config validated: /infra/health exists"
fi

validate_candidate_config "${TEMP_CONF_DIR}"
log_ok "Candidate nginx config validated"

if [ "${ROUTING_MODE}" = "active" ]; then
  log_info "Probing backend health directly on api_network..."
  run_probe_with_retries "Direct backend probe for ${SELECTED_CONTAINER}" probe_backend_direct "${SELECTED_CONTAINER}"
  log_ok "Backend health probe succeeded (${SELECTED_CONTAINER}:3000/health)"
fi

if [ -f "${OUTPUT_FILE}" ]; then
  BACKUP_FILE="${BACKUP_DIR}/api.conf.$(date +%Y%m%dT%H%M%S)"
  cp "${OUTPUT_FILE}" "${BACKUP_FILE}"
  log_info "Backed up existing config -> ${BACKUP_FILE}"
fi

cp "${TEMP_CONF_DIR}/api.conf" "${OUTPUT_FILE}"
log_ok "Config rendered -> ${OUTPUT_FILE}"

if docker ps --format '{{.Names}}' | grep -qx 'nginx'; then
  log_info "Reloading nginx..."
  if ! docker exec nginx nginx -s reload >/dev/null; then
    log_error "nginx reload failed. Rolling back..."
    rollback_live_config
    exit 1
  fi
else
  log_info "Starting nginx..."
  docker compose -f "${NGINX_COMPOSE_FILE}" up -d nginx >/dev/null
fi

if ! wait_for_nginx_running; then
  log_error "nginx failed to reach running state. Rolling back..."
  rollback_live_config
  exit 1
fi

# Post-reload validation: Verify nginx is responding correctly
log_info "Validating nginx responses match expected mode..."

# Always verify /infra/health works (nginx liveness)
INFRA_HEALTH_CODE="$(docker exec nginx sh -c "wget -q -O /dev/null -S http://127.0.0.1/infra/health 2>&1 | grep 'HTTP/' | awk '{print \$2}'" || echo "000")"
if [ "${INFRA_HEALTH_CODE}" != "200" ]; then
  log_error "CRITICAL: /infra/health returned ${INFRA_HEALTH_CODE} (expected 200)"
  rollback_live_config
  exit 1
fi
log_ok "/infra/health correctly returns 200 (nginx is alive)"

if [ "${ROUTING_MODE}" = "maintenance" ]; then
  # In maintenance mode, /health should return 503
  HEALTH_CODE="$(docker exec nginx sh -c "wget -q -O /dev/null -S http://127.0.0.1/health 2>&1 | grep 'HTTP/' | awk '{print \$2}'" || echo "000")"
  if [ "${HEALTH_CODE}" = "502" ]; then
    log_error "CRITICAL: Maintenance /health returned 502 (backend resolution failure)"
    log_error "This means nginx is trying to proxy to backends that don't exist"
    rollback_live_config
    exit 1
  elif [ "${HEALTH_CODE}" = "503" ]; then
    log_ok "Maintenance /health correctly returns 503 (no healthy backend)"
  elif [ "${HEALTH_CODE}" = "200" ]; then
    log_error "CRITICAL: Maintenance /health returned 200 (should be 503)"
    log_error "This masks the fact that no backend is available"
    rollback_live_config
    exit 1
  else
    log_warn "Maintenance /health returned unexpected code: ${HEALTH_CODE} (expected 503)"
  fi

  # Verify response contains "maintenance"
  HEALTH_BODY="$(docker exec nginx sh -c "wget -q -O - http://127.0.0.1/health 2>/dev/null" || echo "")"
  if ! echo "${HEALTH_BODY}" | grep -q "maintenance"; then
    log_error "CRITICAL: Maintenance /health response does not contain 'maintenance'"
    log_error "Response: ${HEALTH_BODY}"
    rollback_live_config
    exit 1
  fi
  log_ok "Maintenance /health response correctly indicates maintenance mode"
fi

if [ "${ROUTING_MODE}" = "active" ]; then
  log_info "Running routed /health probe through nginx..."
  if ! run_probe_with_retries "Routed /health probe through nginx" probe_route_through_nginx; then
    log_error "End-to-end nginx probe failed. Rolling back..."
    rollback_live_config
    exit 1
  fi
  log_ok "Routed /health probe passed"

  log_info "Running routed /ready probe through nginx (non-gating)..."
  if run_probe_with_retries "Routed /ready probe through nginx" probe_ready_through_nginx; then
    log_ok "Routed /ready probe passed"
  else
    log_info "Routed /ready probe did not pass; continuing because /ready is informational here"
  fi
else
  log_info "Running nginx liveness probe in maintenance mode..."
  if ! probe_nginx_liveness; then
    log_error "Maintenance-mode nginx probe failed. Rolling back..."
    rollback_live_config
    exit 1
  fi
  log_ok "Maintenance-mode nginx probe passed"
fi

log_ok "nginx-sync complete - mode: ${ROUTING_MODE}, container_source: ${CONTAINER_SOURCE}, container: ${SELECTED_CONTAINER}"

# Explicit exit with mode validation
echo "[nginx-sync] FINAL MODE: ${ROUTING_MODE}"
if [ "${ROUTING_MODE}" = "maintenance" ] || [ "${ROUTING_MODE}" = "active" ]; then
  echo "[nginx-sync] SUCCESS: valid state"
  exit 0
else
  echo "[nginx-sync] ERROR: invalid state"
  exit 1
fi
