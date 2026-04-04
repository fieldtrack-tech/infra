#!/usr/bin/env bash
# =============================================================================
# scripts/nginx-sync.sh
#
# Safely renders the nginx config and only switches traffic when the selected
# backend is alive on api_network.
#
# Slot ownership contract:
#   - API repo writes /var/lib/fieldtrack/active-slot atomically
#   - Infra repo reads it here and repairs stale/corrupt state when necessary
#
# Usage:
#   bash scripts/nginx-sync.sh
#   bash scripts/nginx-sync.sh --active-slot blue
#   bash scripts/nginx-sync.sh --active-slot blue --allow-missing-backend
#
# Options:
#   --active-slot <blue|green>     Override slot instead of reading from file
#   --allow-missing-backend        Kept for backward compatibility; maintenance
#                                  mode is now used automatically when no
#                                  healthy backend exists
#
# Required environment:
#   API_HOSTNAME   Public hostname served by nginx (no scheme, no slash)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

STATE_DIR="/var/lib/fieldtrack"
ACTIVE_SLOT_FILE="${STATE_DIR}/active-slot"
SLOT_BACKUP_FILE="${STATE_DIR}/active-slot.backup"
LAST_GOOD_FILE="${STATE_DIR}/last-good"
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

ACTIVE_SLOT_OVERRIDE=""
ALLOW_MISSING_BACKEND=false
ACTIVE_SLOT=""
ACTIVE_SLOT_SOURCE="unknown"
SELECTED_SLOT=""
SELECTED_CONTAINER=""
ROUTING_MODE="active"
FALLBACK_USED=false
RECOVERED_SLOT=false
EXPECTED_DEPLOY_SHA="${EXPECTED_DEPLOY_SHA:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --active-slot)
      ACTIVE_SLOT_OVERRIDE="${2:-}"
      shift 2
      ;;
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

is_valid_slot() {
  case "$1" in
    blue|green) return 0 ;;
    *) return 1 ;;
  esac
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
  docker exec nginx sh -eu -c \
    "wget -q --spider --timeout=5 --tries=1 http://127.0.0.1/health"
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

other_slot() {
  case "$1" in
    blue) printf 'green' ;;
    green) printf 'blue' ;;
    *) return 1 ;;
  esac
}

read_slot_from_last_good() {
  if [ ! -f "${LAST_GOOD_FILE}" ]; then
    return 0
  fi

  awk -F= '/^slot=/{print $2}' "${LAST_GOOD_FILE}" 2>/dev/null | tr -d '[:space:]'
}

read_slot_from_live_config() {
  if [ ! -f "${OUTPUT_FILE}" ]; then
    return 0
  fi

  grep -oE 'http://(api-blue|api-green):3000' "${OUTPUT_FILE}" 2>/dev/null \
    | grep -oE 'api-blue|api-green' | head -1 | sed 's/^api-//'
}

backend_is_usable() {
  local slot="$1"
  local container_name="api-${slot}"

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

discover_slot_from_backends() {
  local blue_usable=false
  local green_usable=false
  local live_slot=""

  if backend_is_usable blue; then
    blue_usable=true
  fi

  if backend_is_usable green; then
    green_usable=true
  fi

  if [ "${blue_usable}" = "true" ] && [ "${green_usable}" = "false" ]; then
    printf 'blue'
    return 0
  fi

  if [ "${green_usable}" = "true" ] && [ "${blue_usable}" = "false" ]; then
    printf 'green'
    return 0
  fi

  if [ "${blue_usable}" = "true" ] && [ "${green_usable}" = "true" ]; then
    live_slot="$(read_slot_from_live_config)"
    if is_valid_slot "${live_slot}"; then
      printf '%s' "${live_slot}"
    else
      printf 'blue'
    fi
  fi
}

persist_slot_file() {
  local slot="$1"
  local temp_slot_file

  # Ensure STATE_DIR exists and is writable
  if [ ! -d "${STATE_DIR}" ]; then
    if ! mkdir -p "${STATE_DIR}" 2>/dev/null; then
      log_warn "Cannot create ${STATE_DIR} - slot file will not be persisted"
      return 0
    fi
  fi

  # Create temp file in /tmp first, then move atomically
  temp_slot_file="$(mktemp)"
  printf '%s\n' "${slot}" > "${temp_slot_file}"
  
  if ! mv "${temp_slot_file}" "${ACTIVE_SLOT_FILE}" 2>/dev/null; then
    log_warn "Cannot write to ${ACTIVE_SLOT_FILE} - slot file will not be persisted"
    rm -f "${temp_slot_file}"
    return 0
  fi
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
}

heal_slot_file_if_needed() {
  if [ "${ROUTING_MODE}" != "active" ]; then
    return 0
  fi

  if [ -n "${ACTIVE_SLOT_OVERRIDE}" ] && [ "${RECOVERED_SLOT}" != "true" ] && [ "${FALLBACK_USED}" != "true" ]; then
    return 0
  fi

  if [ "${SELECTED_SLOT}" = "${ACTIVE_SLOT}" ] && [ "${RECOVERED_SLOT}" != "true" ] && [ "${FALLBACK_USED}" != "true" ]; then
    return 0
  fi

  persist_slot_file "${SELECTED_SLOT}"
  log_info "Healed active slot file to '${SELECTED_SLOT}'"
}

resolve_active_slot() {
  local candidate=""

  if [ -n "${ACTIVE_SLOT_OVERRIDE}" ]; then
    if is_valid_slot "${ACTIVE_SLOT_OVERRIDE}"; then
      ACTIVE_SLOT="${ACTIVE_SLOT_OVERRIDE}"
      ACTIVE_SLOT_SOURCE="override"
      log_info "Active slot (override): ${ACTIVE_SLOT}"
      return 0
    fi

    log_warn "Invalid active-slot override '${ACTIVE_SLOT_OVERRIDE}'. Attempting recovery."
  elif [ -f "${ACTIVE_SLOT_FILE}" ]; then
    candidate="$(tr -d '[:space:]' < "${ACTIVE_SLOT_FILE}")"
    if is_valid_slot "${candidate}"; then
      ACTIVE_SLOT="${candidate}"
      ACTIVE_SLOT_SOURCE="slot-file"
      log_info "Active slot (from ${ACTIVE_SLOT_FILE}): ${ACTIVE_SLOT}"
      return 0
    fi

    log_warn "Invalid active slot '${candidate}' in ${ACTIVE_SLOT_FILE}. Attempting recovery."
  else
    log_warn "${ACTIVE_SLOT_FILE} not found. Attempting recovery."
  fi

  if [ -f "${SLOT_BACKUP_FILE}" ]; then
    candidate="$(tr -d '[:space:]' < "${SLOT_BACKUP_FILE}")"
    if is_valid_slot "${candidate}"; then
      ACTIVE_SLOT="${candidate}"
      ACTIVE_SLOT_SOURCE="slot-backup"
      RECOVERED_SLOT=true
      log_info "Recovered active slot from ${SLOT_BACKUP_FILE}: ${ACTIVE_SLOT}"
      return 0
    fi
  fi

  candidate="$(read_slot_from_last_good)"
  if is_valid_slot "${candidate}"; then
    ACTIVE_SLOT="${candidate}"
    ACTIVE_SLOT_SOURCE="last-good"
    RECOVERED_SLOT=true
    log_info "Recovered active slot from ${LAST_GOOD_FILE}: ${ACTIVE_SLOT}"
    return 0
  fi

  candidate="$(read_slot_from_live_config)"
  if is_valid_slot "${candidate}"; then
    ACTIVE_SLOT="${candidate}"
    ACTIVE_SLOT_SOURCE="live-config"
    RECOVERED_SLOT=true
    log_info "Recovered active slot from live nginx config: ${ACTIVE_SLOT}"
    return 0
  fi

  candidate="$(discover_slot_from_backends)"
  if is_valid_slot "${candidate}"; then
    ACTIVE_SLOT="${candidate}"
    ACTIVE_SLOT_SOURCE="backend-discovery"
    RECOVERED_SLOT=true
    log_info "Recovered active slot from healthy backend discovery: ${ACTIVE_SLOT}"
    return 0
  fi

  ACTIVE_SLOT="blue"
  ACTIVE_SLOT_SOURCE="default"
  RECOVERED_SLOT=true
  log_warn "No valid slot metadata or healthy backend was found. Defaulting slot to 'blue' and switching nginx to maintenance mode."
}

select_routing_target() {
  local preferred_slot="$1"
  local alternate_slot

  if backend_is_usable "${preferred_slot}"; then
    SELECTED_SLOT="${preferred_slot}"
    SELECTED_CONTAINER="api-${SELECTED_SLOT}"
    FALLBACK_USED=false
    log_info "Validated preferred backend ${SELECTED_CONTAINER} (healthy on api_network)"
    return 0
  fi

  alternate_slot="$(other_slot "${preferred_slot}")"
  if backend_is_usable "${alternate_slot}"; then
    SELECTED_SLOT="${alternate_slot}"
    SELECTED_CONTAINER="api-${SELECTED_SLOT}"
    FALLBACK_USED=true
    log_info "Preferred slot '${preferred_slot}' is stale or unhealthy."
    log_info "Falling back to healthy slot '${SELECTED_SLOT}' (${SELECTED_CONTAINER})"
    return 0
  fi

  return 1
}

mkdir -p "${STATE_DIR}" "${LIVE_DIR}" "${BACKUP_DIR}"

resolve_active_slot

TARGET_TEMPLATE="${TEMPLATE_FILE}"
ROUTING_MODE="active"

if select_routing_target "${ACTIVE_SLOT}"; then
  :
else
  ROUTING_MODE="maintenance"
  TARGET_TEMPLATE="${MAINTENANCE_TEMPLATE_FILE}"
  SELECTED_SLOT="${ACTIVE_SLOT}"
  SELECTED_CONTAINER="api-${SELECTED_SLOT}"
  if [ "${ALLOW_MISSING_BACKEND}" = "true" ]; then
    log_info "No healthy backend slot was found — rendering maintenance config instead"
  else
    log_warn "No healthy backend slot was found — switching nginx to maintenance mode"
  fi
fi

TEMP_CONF_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "${TEMP_CONF_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

render_template "${TARGET_TEMPLATE}" "${TEMP_CONF_DIR}/api.conf"
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

  heal_slot_file_if_needed
else
  log_info "Running nginx liveness probe in maintenance mode..."
  if ! probe_nginx_liveness; then
    log_error "Maintenance-mode nginx probe failed. Rolling back..."
    rollback_live_config
    exit 1
  fi
  log_ok "Maintenance-mode nginx probe passed"
fi

log_ok "nginx-sync complete - mode: ${ROUTING_MODE}, slot_source: ${ACTIVE_SLOT_SOURCE}, requested slot: ${ACTIVE_SLOT}, routed slot: ${SELECTED_SLOT}, container: ${SELECTED_CONTAINER}"

# Explicit exit with mode validation
echo "[nginx-sync] FINAL MODE: ${ROUTING_MODE}"
if [ "${ROUTING_MODE}" = "maintenance" ] || [ "${ROUTING_MODE}" = "active" ]; then
  echo "[nginx-sync] SUCCESS: valid state"
  exit 0
else
  echo "[nginx-sync] ERROR: invalid state"
  exit 1
fi
