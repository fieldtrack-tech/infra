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
#   API_BACKEND_CONTAINER   Docker container name on api_network (default: auto-discovers api-green then api-blue)
#   EXPECTED_DEPLOY_SHA     When set, backend image labels must match
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Path validation
#
# On production the repo must live at /opt/infra so that all tooling
# (watchdog cron, deploy scripts, container volume mounts) agree on one
# canonical path.  In CI (GitHub Actions sets CI=true automatically)
# the workspace is /home/runner/work/<repo>/<repo> — this is the correct
# and expected path for CI; no warning is needed or useful there.
# ---------------------------------------------------------------------------
EXPECTED_INFRA_ROOT="/opt/infra"
if [ "${INFRA_DIR}" != "${EXPECTED_INFRA_ROOT}" ] && [ "${CI:-false}" != "true" ]; then
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

# ---------------------------------------------------------------------------
# extract_nginx_location_blocks FILE LOCATION_SPEC
#
# Brace-aware extractor: outputs the full text of every nginx location block
# whose opening line contains LOCATION_SPEC. Uses brace counting so nested
# braces inside the block do not prematurely end the extraction.
#
# This replaces all fragile `grep -A N 'location = /...' | grep '...'` patterns
# which fail whenever the block has more lines than N or when grep picks up
# content from neighbouring blocks (e.g. the HTTP 301-redirect block being
# matched alongside the HTTPS proxy_pass block).
# ---------------------------------------------------------------------------
extract_nginx_location_blocks() {
  local file="$1"
  local location_spec="$2"
  awk -v spec="${location_spec}" '
    !in_block && index($0, spec) > 0 && /location/ {
      in_block = 1
      depth = 0
      buf = ""
    }
    in_block {
      buf = buf $0 "\n"
      n = split($0, chars, "")
      for (i = 1; i <= n; i++) {
        if (chars[i] == "{") depth++
        else if (chars[i] == "}") {
          depth--
          if (depth == 0) {
            printf "%s", buf
            in_block = 0
            buf = ""
            break
          }
        }
      }
    }
  ' "${file}"
}

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

  # grep exits 1 when there is no match (e.g. the live config is in maintenance
  # mode and has no `set $api_backend` directive).  With set -o pipefail that
  # non-zero exit propagates through the pipeline and set -e would abort the
  # script.  `|| true` suppresses it so the function always returns 0 and the
  # caller receives an empty string when nothing is found.
  grep -oE 'set \$api_backend "http://[a-zA-Z0-9_.-]+:3000"' "${OUTPUT_FILE}" 2>/dev/null \
    | head -1 \
    | sed -n 's/.*http:\/\/\([a-zA-Z0-9_.-]*\):3000.*/\1/p' || true
}

resolve_backend_container() {
  local candidate=""

  # 1. Explicit override via environment variable (highest priority)
  if [ -n "${API_BACKEND_CONTAINER:-}" ]; then
    if backend_name_valid "${API_BACKEND_CONTAINER}"; then
      SELECTED_CONTAINER="${API_BACKEND_CONTAINER}"
      CONTAINER_SOURCE="env"
      log_info "Backend container (from API_BACKEND_CONTAINER): ${SELECTED_CONTAINER}"
      return 0
    fi
    log_warn "Invalid API_BACKEND_CONTAINER '${API_BACKEND_CONTAINER}'. Ignoring."
  fi

  # 2. Try the container recorded in the live config, but ONLY if it still exists.
  # Do NOT use a stale container name — if it no longer exists, fall through to
  # auto-discovery so we pick up the new active container (prevents oscillation
  # during blue-green switches where the old slot is removed before the new one
  # is healthy).
  candidate="$(read_backend_from_live_config)"
  if [ -n "${candidate}" ] && backend_name_valid "${candidate}" && backend_exists "${candidate}" 2>/dev/null; then
    SELECTED_CONTAINER="${candidate}"
    CONTAINER_SOURCE="live-config"
    log_info "Backend container (from live nginx config, verified present): ${SELECTED_CONTAINER}"
    return 0
  elif [ -n "${candidate}" ]; then
    log_info "Live config referenced '${candidate}' but container is gone — falling through to auto-discover"
  fi

  # 3. Auto-discover blue/green deployment containers in preference order
  local disc_candidate
  for disc_candidate in "api-green" "api-blue"; do
    if backend_exists "${disc_candidate}" 2>/dev/null; then
      SELECTED_CONTAINER="${disc_candidate}"
      CONTAINER_SOURCE="auto-discover"
      log_info "Backend container (auto-discovered): ${SELECTED_CONTAINER}"
      return 0
    fi
  done

  # 4. No container found — use default name so backend_is_usable can fail gracefully
  SELECTED_CONTAINER="api-green"
  CONTAINER_SOURCE="default"
  log_info "Backend container (default, no running container found): ${SELECTED_CONTAINER}"
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
  # Run nginx -t WITHOUT >/dev/null so any syntax errors are always visible
  # in CI logs. nginx sends its output to stderr by default; we capture both
  # stdout+stderr and prefix each line so it's easy to spot in the job log.
  local output
  if ! output="$(docker run --rm \
    -v "${candidate_dir}:/etc/nginx/conf.d:ro" \
    -v /etc/ssl/api:/etc/ssl/api:ro \
    -v /var/www/certbot:/var/www/certbot:ro \
    -v /var/log/nginx:/var/log/nginx \
    nginx:1.25-alpine \
    nginx -t 2>&1)"; then
    log_error "nginx -t config validation failed:"
    printf '%s\n' "${output}" | sed 's/^/  [nginx-t] /' >&2
    return 1
  fi
  # Print nginx -t output at INFO level even on success (shows 'test is successful')
  printf '%s\n' "${output}" | sed 's/^/  [nginx-t] /'
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

# ---------------------------------------------------------------------------
# HTTP probes — all run on the HOST using curl, NOT inside the nginx container.
#
# Rationale: the nginx container runs Alpine with BusyBox wget. BusyBox wget:
#   - Does not guarantee a clean 3-digit status code from `wget -S` output
#     (CRLF line endings, format varies across BusyBox versions)
#   - Does NOT write the response body to stdout for non-2xx responses when
#     the shell `|| echo ""` pattern is used (exit-code propagation)
#   - The `--spider` option exits non-zero for anything outside 2xx/3xx,
#     but gives no HTTP status code to parse
#
# curl on the host (Ubuntu CI / Debian VPS) is deterministic:
#   `curl -s -o /dev/null -w "%{http_code}"` always emits exactly 3 digits
#   `curl -s` emits the full response body regardless of HTTP status code
# ---------------------------------------------------------------------------
probe_nginx_liveness() {
  # /infra/health is answered by nginx directly — never depends on backend.
  # Use -f (--fail) so curl exits non-zero for any non-2xx response.
  curl -sf --max-time 5 \
    -H "Host: ${API_HOSTNAME}" \
    http://127.0.0.1/infra/health >/dev/null 2>&1
}

probe_route_through_nginx() {
  # HTTPS probe: use --resolve to route to 127.0.0.1 while sending correct
  # SNI/Host. -k skips cert verification (self-signed on VPS; CI uses self-signed).
  # -f exits non-zero for 4xx/5xx so the caller can detect failures.
  curl -sf --max-time 10 -k \
    --resolve "${API_HOSTNAME}:443:127.0.0.1" \
    "https://${API_HOSTNAME}/health" >/dev/null 2>&1
}

probe_ready_through_nginx() {
  curl -sf --max-time 10 -k \
    --resolve "${API_HOSTNAME}:443:127.0.0.1" \
    "https://${API_HOSTNAME}/ready" >/dev/null 2>&1
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
log_info "Directories ready: ${LIVE_DIR}, ${BACKUP_DIR}"

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

# Create the temp dir INSIDE LIVE_DIR so that the final mv is within the same
# filesystem — POSIX guarantees rename(2) is atomic only within one filesystem.
# If we used /tmp (the mktemp default), mv across a filesystem boundary would
# silently fall back to a copy+delete, which is NOT atomic.
TEMP_CONF_DIR="$(mktemp -d "${LIVE_DIR}/tmp.XXXXXXXXXX")"
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

  # Verify maintenance /health block returns 503.
  # Uses brace-aware extraction — avoids grep -A N which fails when the block
  # has more lines than N (maintenance /health has 5 lines: access_log,
  # default_type, charset, return 503, closing brace).
  _health_blocks="$(extract_nginx_location_blocks "${TEMP_CONF_DIR}/api.conf" 'location = /health')"
  if ! printf '%s\n' "${_health_blocks}" | grep -q 'return 503'; then
    log_error "CRITICAL: Maintenance /health does not return 503"
    log_error "Maintenance mode MUST return 503 for /health to signal unhealthy state"
    log_error "Extracted /health blocks:"
    printf '%s\n' "${_health_blocks}" | sed 's/^/  /' >&2
    exit 1
  fi
  log_ok "Maintenance config validated: /health returns 503"

  # Verify /infra/health exists and returns 200
  _infra_blocks="$(extract_nginx_location_blocks "${TEMP_CONF_DIR}/api.conf" 'location = /infra/health')"
  if [ -z "${_infra_blocks}" ]; then
    log_error "CRITICAL: Maintenance config missing /infra/health endpoint"
    exit 1
  fi
  if ! printf '%s\n' "${_infra_blocks}" | grep -q 'return 200'; then
    log_error "CRITICAL: Maintenance /infra/health does not return 200"
    exit 1
  fi
  log_ok "Maintenance config validated: /infra/health exists and returns 200"
else
  # Active mode MUST have proxy_pass or upstream
  if ! grep -v "^[[:space:]]*#" "${TEMP_CONF_DIR}/api.conf" | grep -qE "proxy_pass|upstream"; then
    log_error "CRITICAL: Active config missing proxy directives"
    exit 1
  fi
  log_ok "Active config validated: has proxy directives"

  # Verify active /health location blocks:
  # (a) At least one must have proxy_pass (the HTTPS block must proxy, not return statically)
  # (b) None must have 4xx/5xx static return codes
  # Uses brace-aware extraction to avoid false-positive from the HTTP block's
  # `return 301 https://...` redirect (which is intentional and NOT an error).
  _health_blocks="$(extract_nginx_location_blocks "${TEMP_CONF_DIR}/api.conf" 'location = /health')"
  if ! printf '%s\n' "${_health_blocks}" | grep -q 'proxy_pass'; then
    log_error "CRITICAL: Active /health does not contain proxy_pass — HTTPS block must proxy to backend"
    log_error "Extracted /health blocks:"
    printf '%s\n' "${_health_blocks}" | sed 's/^/  /' >&2
    exit 1
  fi
  if printf '%s\n' "${_health_blocks}" | grep -qE 'return[[:space:]]+[45][0-9][0-9]'; then
    log_error "CRITICAL: Active /health contains a 4xx/5xx static return (only 301 redirect is permitted in HTTP block)"
    log_error "Extracted /health blocks:"
    printf '%s\n' "${_health_blocks}" | sed 's/^/  /' >&2
    exit 1
  fi
  log_ok "Active config validated: /health proxies to backend"

  # Verify /infra/health exists and returns 200
  _infra_blocks="$(extract_nginx_location_blocks "${TEMP_CONF_DIR}/api.conf" 'location = /infra/health')"
  if [ -z "${_infra_blocks}" ]; then
    log_error "CRITICAL: Active config missing /infra/health endpoint"
    exit 1
  fi
  if ! printf '%s\n' "${_infra_blocks}" | grep -q 'return 200'; then
    log_error "CRITICAL: Active /infra/health does not return 200"
    exit 1
  fi
  log_ok "Active config validated: /infra/health exists and returns 200"
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

# Atomic rename: mv within the same filesystem is POSIX-guaranteed atomic.
# This means nginx never reads a half-written config during a hot reload —
# it sees either the old file or the new file, never a partial write.
# (Using cp instead would leave a window where nginx could reload mid-write.)
mv "${TEMP_CONF_DIR}/api.conf" "${OUTPUT_FILE}"
log_ok "Config written atomically -> ${OUTPUT_FILE}"

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

# Allow nginx to finish spawning new workers with the reloaded config before
# probing. `nginx -s reload` sends HUP and returns immediately; there is a
# brief window where old workers (running the previous config) still answer
# requests. 1 second is sufficient for nginx to complete the transition in
# both CI and production environments.
sleep 1

# Post-reload validation: Verify nginx is responding correctly
log_info "Validating nginx responses match expected mode..."

# Always verify /infra/health works (nginx liveness)
# curl -s -o /dev/null -w "%{http_code}" always yields exactly 3 decimal digits
# with no CRLF, no extra text — safe for direct string comparison.
INFRA_HEALTH_CODE="$(curl -s -o /dev/null -w "%{http_code}" \
  --max-time 5 \
  -H "Host: ${API_HOSTNAME}" \
  http://127.0.0.1/infra/health 2>/dev/null || echo "000")"
if [ "${INFRA_HEALTH_CODE}" != "200" ]; then
  log_error "CRITICAL: /infra/health returned ${INFRA_HEALTH_CODE} (expected 200)"
  rollback_live_config
  exit 1
fi
log_ok "/infra/health correctly returns 200 (nginx is alive)"

if [ "${ROUTING_MODE}" = "maintenance" ]; then
  # In maintenance mode, /health must return 503 with a body containing 'maintenance'.
  # Use HTTPS (same as all other probes in this script) via --resolve so curl
  # reaches 127.0.0.1 while sending the correct SNI/Host. -k skips cert
  # verification (self-signed in CI and on VPS before Let's Encrypt runs).
  #
  # Why NOT plain HTTP: the active config's HTTP server block has
  # `location = /health { return 301 ... }`. If the post-reload probe races
  # against a still-running old worker, HTTP returns 301 which is
  # indistinguishable from a real failure. HTTPS is unambiguous:
  #   - Active config (old worker, dead backend) → 502
  #   - Maintenance config (new worker)          → 503  ← expected
  # curl -s outputs the body even for non-2xx responses.
  HEALTH_CODE="$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time 5 -k \
    --resolve "${API_HOSTNAME}:443:127.0.0.1" \
    "https://${API_HOSTNAME}/health" 2>/dev/null || echo "000")"
  HEALTH_BODY="$(curl -s \
    --max-time 5 -k \
    --resolve "${API_HOSTNAME}:443:127.0.0.1" \
    "https://${API_HOSTNAME}/health" 2>/dev/null || echo "")"

  if [ "${HEALTH_CODE}" = "503" ]; then
    log_ok "Maintenance /health correctly returns 503 (no healthy backend)"
  elif [ "${HEALTH_CODE}" = "502" ]; then
    log_error "CRITICAL: Maintenance /health returned 502"
    log_error "Nginx is still proxying /health to the dead backend — maintenance template has proxy_pass"
    rollback_live_config
    exit 1
  elif [ "${HEALTH_CODE}" = "200" ]; then
    log_error "CRITICAL: Maintenance /health returned 200 (should be 503)"
    log_error "This masks the fact that no backend is available"
    rollback_live_config
    exit 1
  else
    log_error "CRITICAL: Maintenance /health returned unexpected code: ${HEALTH_CODE} (expected 503)"
    log_error "Probe: HTTPS ${API_HOSTNAME}/health via --resolve to 127.0.0.1"
    rollback_live_config
    exit 1
  fi

  # Verify response body contains 'maintenance' — proves the static JSON body
  # from the return directive is being served, not nginx's default error page.
  if ! printf '%s' "${HEALTH_BODY}" | grep -q 'maintenance'; then
    log_error "CRITICAL: Maintenance /health response body does not contain 'maintenance'"
    log_error "Expected: {\"status\":\"maintenance\",...}"
    log_error "Received: ${HEALTH_BODY}"
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
