#!/usr/bin/env bash
# =============================================================================
# scripts/nginx-sync.sh
#
# Health-based nginx routing controller.
# Probes api-blue and api-green on every run and routes to whichever backend
# is stable and reachable from both host and nginx network.
#
# CANONICAL PATH: /opt/infra
#
# Usage:
#   bash scripts/nginx-sync.sh
#   bash scripts/nginx-sync.sh --allow-missing-backend
#
# Options:
#   --allow-missing-backend   Suppress the warning when entering maintenance mode
#
# Required environment:
#   API_HOSTNAME   Public hostname served by nginx (no scheme, no slash)
# =============================================================================

set -euo pipefail

INFRA_ROOT="/opt/infra"
STATE_DIR="/var/lib/fieldtrack"
LOG_DIR="/var/log/fieldtrack"

if [ -f "${INFRA_ROOT}/.env.monitoring" ]; then
  set -a
  source "${INFRA_ROOT}/.env.monitoring"
  set +a
fi

TEMPLATE_FILE="${INFRA_ROOT}/nginx/api.conf"
MAINTENANCE_TEMPLATE_FILE="${INFRA_ROOT}/nginx/api.maintenance.conf"
LIVE_DIR="${INFRA_ROOT}/nginx/live"
BACKUP_DIR="${INFRA_ROOT}/nginx/backup"
OUTPUT_FILE="${LIVE_DIR}/api.conf"
NGINX_COMPOSE_FILE="${INFRA_ROOT}/docker-compose.nginx.yml"

log_info()  { printf '[nginx-sync] INFO  %s\n' "$*"; }
log_warn()  { printf '[nginx-sync] WARN  %s\n' "$*" >&2; }
log_error() { printf '[nginx-sync] ERROR %s\n' "$*" >&2; }
log_ok()    { printf '[nginx-sync] OK    %s\n' "$*"; }

ALLOW_MISSING_BACKEND=false
ACTIVE_SLOT=""
ACTIVE_SLOT_SOURCE="unknown"
ACTIVE_SLOT_ACTION="SWITCH"  # SWITCH or NO-OP
SELECTED_SLOT=""
SELECTED_CONTAINER=""
ROUTING_MODE="active"
EXPECTED_DEPLOY_SHA="${EXPECTED_DEPLOY_SHA:-}"
ORIGINAL_ARGS=("$@")

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
  local slot="$1"
  local container_name="api-${slot}"

  if ! backend_exists "${container_name}" || ! backend_running "${container_name}" || \
     ! backend_attached_to_network "${container_name}" || ! backend_matches_expected_sha "${container_name}"; then
    return 1
  fi

  log_info "Evaluating backend stability for ${container_name}..."
  local success=0
  for i in 1 2 3; do
    # 1. Host trace validation
    if docker run --rm --network api_network --entrypoint sh nginx:1.25-alpine -eu -c "wget -q --spider --timeout=5 --tries=1 http://${container_name}:3000/health" >/dev/null 2>&1; then
      # 2. Split-brain Nginx container reachability assertion
      if docker ps -q --filter "name=^nginx$" | grep -q . ; then
          if docker exec nginx sh -eu -c "wget -qO- http://${container_name}:3000/health" >/dev/null 2>&1; then
            success=$((success+1))
          fi
      else
          # Nginx not running locally yet? Map host success accurately.
          success=$((success+1))
      fi
    fi
    sleep 1
  done

  mkdir -p /var/log/fieldtrack
  if [ "${success}" -ge 3 ]; then
    log_ok "${container_name} is STABLE_HEALTHY (Passed 3/3)"
    echo "$(date -u +%FT%TZ) | ${container_name} | STABLE_HEALTHY | reachability_passed_3_of_3" >> /var/log/fieldtrack/nginx-sync.log || true
    return 0
  else
    log_warn "${container_name} is UNSTABLE (Passed ${success}/3)"
    echo "$(date -u +%FT%TZ) | ${container_name} | UNSTABLE | reachability_passed_${success}_of_3" >> /var/log/fieldtrack/nginx-sync.log || true
    return 1
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

  log_error "=== ROLLBACK DEBUGGING INFO ==="
  log_error "Active slot: ${ACTIVE_SLOT:-unknown}"
  log_error "Selected slot: ${SELECTED_SLOT:-unknown}"
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

resolve_active_slot() {
  local blue_usable=false
  local green_usable=false

  mkdir -p "${LOG_DIR}"
  touch "${LOG_DIR}/nginx-sync.log"

  # ── Step 1 & 2: Evaluate each backend (stable + nginx reachable) ──────────
  log_info "Probing blue backend health..."
  if backend_is_usable blue; then blue_usable=true; fi

  log_info "Probing green backend health..."
  if backend_is_usable green; then green_usable=true; fi

  # ── Step 5: Guard against premature maintenance (2s double-check) ─────────
  if [ "${blue_usable}" = "false" ] && [ "${green_usable}" = "false" ]; then
    log_warn "Both backends unresponsive. Waiting 2s before confirming maintenance..."
    sleep 2
    log_info "Re-probing blue backend..."
    if backend_is_usable blue; then blue_usable=true; fi
    log_info "Re-probing green backend..."
    if backend_is_usable green; then green_usable=true; fi
  fi

  # ── Determine current nginx backend from live config ──────────────────────
  local CURRENT_MOUNTED
  CURRENT_MOUNTED="$(grep -oE 'http://(api-blue|api-green):' "${OUTPUT_FILE}" 2>/dev/null \
    | grep -oE 'api-blue|api-green' | head -1 | sed 's/^api-//' || true)"

  # Telemetry shorthand
  local blue_status green_status
  blue_status="$( [ "${blue_usable}" = "true" ] && echo "stable" || echo "unstable" )"
  green_status="$( [ "${green_usable}" = "true" ] && echo "stable" || echo "unstable" )"

  local healthy=""
  [ "${blue_usable}" = "true" ]  && healthy="blue"
  [ "${green_usable}" = "true" ] && healthy="${healthy:+${healthy} }green"
  HEALTHY_CONTAINERS="${healthy}"

  # ── Step 3/4: Decision logic (FINAL ORDER — must not change) ─────────────
  #
  # Priority:
  #   1. Both valid  → keep current backend (no-op) if current is still valid,
  #                    else switch to other valid backend.
  #   2. One valid   → use that backend.
  #   3. None valid  → maintenance (already double-checked above).

  if [ "${blue_usable}" = "true" ] && [ "${green_usable}" = "true" ]; then
    # BOTH healthy — only switch if current backend is no longer valid.
    if is_valid_slot "${CURRENT_MOUNTED}" && backend_is_usable "${CURRENT_MOUNTED}"; then
      ACTIVE_SLOT="${CURRENT_MOUNTED}"
      ACTIVE_SLOT_SOURCE="current-backend-guard"
      ACTIVE_SLOT_ACTION="NO-OP"
      log_ok "Both backends healthy. Current backend '${CURRENT_MOUNTED}' still valid — keeping it."
    else
      # Current backend is gone/unknown — pick the other valid one.
      # Prefer blue as the tiebreaker when current is unknown.
      if [ "${CURRENT_MOUNTED}" = "green" ]; then
        ACTIVE_SLOT="blue"
      else
        ACTIVE_SLOT="green"
      fi
      ACTIVE_SLOT_SOURCE="both-healthy-switch"
      ACTIVE_SLOT_ACTION="SWITCH"
      log_warn "Both backends healthy but current '${CURRENT_MOUNTED}' invalid — switching to '${ACTIVE_SLOT}'."
    fi

  elif [ "${blue_usable}" = "true" ]; then
    ACTIVE_SLOT="blue"
    ACTIVE_SLOT_SOURCE="health-primary"
    ACTIVE_SLOT_ACTION="$( [ "${CURRENT_MOUNTED}" = "blue" ] && echo "NO-OP" || echo "SWITCH" )"

  elif [ "${green_usable}" = "true" ]; then
    ACTIVE_SLOT="green"
    ACTIVE_SLOT_SOURCE="health-primary"
    ACTIVE_SLOT_ACTION="$( [ "${CURRENT_MOUNTED}" = "green" ] && echo "NO-OP" || echo "SWITCH" )"

  else
    ACTIVE_SLOT="none"
    ACTIVE_SLOT_SOURCE="health-primary"
    ACTIVE_SLOT_ACTION="SWITCH"
  fi

  # ── Structured run summary log ────────────────────────────────────────────
  printf '%s | blue=%s | green=%s | blue_nginx_reach=%s | green_nginx_reach=%s | current=%s | selected=%s | source=%s | action=%s | mode=%s\n' \
    "$(date -u +%FT%TZ)" \
    "${blue_status}" \
    "${green_status}" \
    "${blue_usable}" \
    "${green_usable}" \
    "${CURRENT_MOUNTED:-none}" \
    "${ACTIVE_SLOT}" \
    "${ACTIVE_SLOT_SOURCE}" \
    "${ACTIVE_SLOT_ACTION}" \
    "$( [ "${ACTIVE_SLOT}" = "none" ] && echo "maintenance" || echo "active" )" \
    >> "${LOG_DIR}/nginx-sync.log" || true
}

select_routing_target() {
  if [ "${ACTIVE_SLOT}" = "none" ]; then
    return 1 # Maintenance mode
  fi

  SELECTED_SLOT="${ACTIVE_SLOT}"
  SELECTED_CONTAINER="api-${SELECTED_SLOT}"
  log_info "Selected backend ${SELECTED_CONTAINER} via ${ACTIVE_SLOT_SOURCE}"
  return 0
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
  SELECTED_SLOT="maintenance"
  SELECTED_CONTAINER="none"
  if [ "${ALLOW_MISSING_BACKEND}" = "true" ]; then
    log_info "No healthy backend found — rendering maintenance config"
  else
    log_warn "No healthy backend found — switching nginx to maintenance mode"
  fi
fi

TEMP_CONF_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "${TEMP_CONF_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

render_template "${TARGET_TEMPLATE}" "${TEMP_CONF_DIR}/api.conf"

# ================================================================
# Idempotency guard — skip all config writing if already matches
# ================================================================
if [ -f "${OUTPUT_FILE}" ]; then
  if diff -q "${TEMP_CONF_DIR}/api.conf" "${OUTPUT_FILE}" >/dev/null 2>&1; then
    # Config on disk already matches what we would write. Only proceed if
    # nginx is missing or /infra/health is broken.
    if docker ps -q --filter "name=^nginx$" | grep -q . \
       && curl -fsS -o /dev/null -w "%{http_code}" http://localhost/infra/health 2>/dev/null | grep -q '200'; then
      log_ok "[NO-OP] Rendered config identical to disk and nginx is healthy. Nothing to do."
      printf '%s | action=NO-OP | reason=config-identical\n' "$(date -u +%FT%TZ)" >> "${LOG_DIR}/nginx-sync.log" || true
      exit 0
    fi
    log_warn "Config identical to disk but nginx is unhealthy — reloading anyway."
  fi
fi

# CRITICAL: Validate config matches expected mode
log_info "Validating rendered config matches mode: ${ROUTING_MODE}"
if [ "${ROUTING_MODE}" = "maintenance" ]; then
  # Maintenance mode MUST NOT have proxy directives
  if grep -v "^[[:space:]]*#" "${TEMP_CONF_DIR}/api.conf" | grep -qE "proxy_pass|upstream|api-blue|api-green"; then
    log_error "CRITICAL: Maintenance config contains proxy directives or backend references"
    log_error "This will cause 502 errors. Config validation failed."
    grep -n "proxy_pass\|upstream\|api-blue\|api-green" "${TEMP_CONF_DIR}/api.conf" || true
    exit 1
  fi
  log_ok "Maintenance config validated: no proxy directives"
  
  # Verify maintenance config returns 503 for /health
  if ! grep -A 5 'location = /health' "${TEMP_CONF_DIR}/api.conf" | grep -q "return 503"; then
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
  log_info "Safely reloading nginx..."
  RELOAD_FAILED=false
  if ! docker exec nginx nginx -s reload >/dev/null; then
    log_warn "Standard nginx reload failed or exit non-zero."
    RELOAD_FAILED=true
  fi
  sleep 1

  # Check config drift
  log_info "Validating runtime config consistency..."
  RUNTIME_CONFIG="$(docker exec nginx cat /etc/nginx/conf.d/api.conf 2>/dev/null || true)"
  DISK_CONFIG="$(cat "${OUTPUT_FILE}")"

  # Verify deterministic nginx mount
  MOUNT_PATH="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/etc/nginx/conf.d"}}{{.Source}}{{end}}{{end}}' nginx 2>/dev/null || true)"
  if [[ "${MOUNT_PATH}" != *"/nginx/live" ]]; then
    log_error "CRITICAL: Nginx mount path is incorrect: ${MOUNT_PATH}"
    RELOAD_FAILED=true
  fi

  if [ "${RUNTIME_CONFIG}" != "${DISK_CONFIG}" ] || [ "${RELOAD_FAILED}" = "true" ]; then
    log_warn "Config drift or reload failure detected! Restarting nginx container (Self-Healing)..."
    docker compose -f "${NGINX_COMPOSE_FILE}" up -d --force-recreate nginx >/dev/null
    sleep 2
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

  # Wait until system stabilizes
  log_info "Waiting for system validation to stabilize (max 30s)..."
  CONVERGED=false
  for i in $(seq 1 30); do
    MATCH=true
    
    if [ "${ROUTING_MODE}" = "maintenance" ]; then
      HEALTH_CODE="$(curl -s -o /dev/null -w "%{http_code}" -H "Host: ${API_HOSTNAME}" http://localhost/health || echo "000")"
      HEALTH_BODY="$(curl -s -H "Host: ${API_HOSTNAME}" http://localhost/health 2>/dev/null || echo "")"
      if [ "${HEALTH_CODE}" != "503" ] || ! echo "${HEALTH_BODY}" | grep -q "maintenance"; then
        MATCH=false
      fi
    else
      if ! probe_route_through_nginx >/dev/null 2>&1; then
        MATCH=false
      else
        ACTIVE_HEALTH_BODY="$(curl -s -H "Host: ${API_HOSTNAME}" http://localhost/health 2>/dev/null || echo "")"
        if echo "${ACTIVE_HEALTH_BODY}" | grep -q "maintenance"; then
          MATCH=false
        fi
      fi
    fi

    if [ "${MATCH}" = "true" ]; then
      log_ok "System converged at iteration ${i}."
      CONVERGED=true
      break
    fi
    sleep 1
  done

  if [ "${CONVERGED}" = "false" ]; then
    log_warn "--- DRIFT TELEMETRY ---"
    log_warn "Active Slot Target: ${ACTIVE_SLOT}"
    log_warn "Healthy Detected: ${HEALTHY_CONTAINERS}"
    log_warn "Routing Mode Set: ${ROUTING_MODE}"
    if [ "${ROUTING_MODE}" = "active" ]; then
      log_warn "Last Curl Out: ${ACTIVE_HEALTH_BODY}"
    else
      log_warn "Last Curl Out (Code ${HEALTH_CODE}): ${HEALTH_BODY}"
    fi
    log_warn "-----------------------"
    
    export NGINX_SYNC_RETRY=$(( ${NGINX_SYNC_RETRY:-0} + 1 ))
    if [ "${NGINX_SYNC_RETRY}" -le 1 ]; then
      log_warn "Convergence timed out. Retrying nginx-sync once (attempt ${NGINX_SYNC_RETRY}/1)..."
      exec bash "$0" "${ORIGINAL_ARGS[@]:-}"
    else
      log_error "CRITICAL: Convergence failed after retry. Rolling back."
      rollback_live_config
      exit 1
    fi
  fi
  
  if [ "${ROUTING_MODE}" = "active" ]; then
    log_info "Running routed /ready probe through nginx (non-gating)..."
    if run_probe_with_retries "Routed /ready probe through nginx" probe_ready_through_nginx; then
      log_ok "Routed /ready probe passed"
    else
      log_info "Routed /ready probe did not pass; continuing because /ready is informational here"
    fi
    heal_slot_file_if_needed
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
