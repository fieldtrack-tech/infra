#!/usr/bin/env bash
# =============================================================================
# scripts/bootstrap.sh
#
# First-time VPS setup for FieldTrack core infra.
# Creates api_network, starts Redis, validates it, and starts nginx safely.
#
# Runs identically in CI (no sudo, temp dirs) and on VPS (real paths, sudo).
#
# CANONICAL PATH: /opt/infra
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

# ---------------------------------------------------------------------------
# CI vs VPS detection
# ---------------------------------------------------------------------------
# CI=true is set automatically by GitHub Actions and most CI systems.
IS_CI="${CI:-false}"

# In CI, never use sudo and redirect state/log dirs to writable temp paths.
if [ "${IS_CI}" = "true" ]; then
  STATE_DIR="/tmp/fieldtrack/state"
  LOG_DIR="/tmp/fieldtrack/log"
else
  STATE_DIR="/var/lib/fieldtrack"
  LOG_DIR="/var/log/fieldtrack"
fi

# maybe_sudo <cmd> [...args]
# Runs cmd with sudo on VPS, directly in CI.
# Falls back to direct execution if sudo is not available even on VPS
# (e.g. root user, minimal image).
maybe_sudo() {
  if [[ "${IS_CI:-false}" == "true" ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    "$@"
  fi
}

log_info()  { printf '[bootstrap] INFO  %s\n' "$*"; }
log_warn()  { printf '[bootstrap] WARN  %s\n' "$*" >&2; }
log_error() { printf '[bootstrap] ERROR %s\n' "$*" >&2; }
log_ok()    { printf '[bootstrap] OK    %s\n' "$*"; }

# ---------------------------------------------------------------------------
# ensure_directory_ready <dir>
#
# Creates the directory if missing, fixes ownership, verifies writability.
# Uses sudo only on VPS (IS_CI=false).
# Exits 1 with a clear error if the directory cannot be made writable.
# ---------------------------------------------------------------------------
ensure_directory_ready() {
  local dir="$1"

  # 1. Create if missing
  if [ ! -d "${dir}" ]; then
    log_info "Creating directory: ${dir}"
    if ! maybe_sudo mkdir -p "${dir}" 2>/dev/null; then
      log_error "Cannot create ${dir} — permission denied"
      return 1
    fi
  fi

  # 2. Fix ownership ONLY if not writable — avoid unnecessary chown churn
  if [ ! -w "${dir}" ]; then
    log_warn "${dir} not writable — fixing ownership..."
    if ! maybe_sudo chown -R "$(id -un):$(id -gn)" "${dir}" 2>/dev/null; then
      log_error "Cannot fix ownership of ${dir}"
      return 1
    fi
    # Normalize permissions only when we had to intervene
    maybe_sudo chmod 755 "${dir}" 2>/dev/null || true
  fi

  # 3. Final strict writability assertion via actual write test
  if ! touch "${dir}/.write-test" 2>/dev/null; then
    log_error "${dir} is still not writable after ownership fix — cannot continue"
    return 1
  fi
  rm -f "${dir}/.write-test"

  log_ok "Directory ready: ${dir}"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
WITH_MONITORING=false
for arg in "$@"; do
  case "$arg" in
    --with-monitoring) WITH_MONITORING=true ;;
    *) log_error "Unknown argument: $arg"; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Step 0: Log dir must be ready before anything else writes to it
# ---------------------------------------------------------------------------
log_info "Bootstrapping log directory: ${LOG_DIR}"
ensure_directory_ready "${LOG_DIR}"

# ---------------------------------------------------------------------------
# Step 1: Infra location check (warn only — supports CI checkout paths)
# ---------------------------------------------------------------------------
EXPECTED_INFRA_ROOT="/opt/infra"
if [ "${INFRA_DIR}" != "${EXPECTED_INFRA_ROOT}" ]; then
  log_warn "Running from ${INFRA_DIR} instead of ${EXPECTED_INFRA_ROOT}"
  if [ "${IS_CI}" != "true" ]; then
    log_warn "For production, infra should be cloned to ${EXPECTED_INFRA_ROOT}"

    # Ensure /opt/infra exists on VPS
    if [ ! -d "${EXPECTED_INFRA_ROOT}" ]; then
      ensure_directory_ready "${EXPECTED_INFRA_ROOT}"
    fi

    # Clone repo to canonical path if not present
    if [ ! -d "${EXPECTED_INFRA_ROOT}/.git" ]; then
      git clone https://github.com/fieldtrack-tech/infra.git "${EXPECTED_INFRA_ROOT}"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Step 2: Validate infra repository completeness
# ---------------------------------------------------------------------------
log_info "Validating infra repository completeness..."

REQUIRED_FILES=(
  "${INFRA_DIR}/nginx/api.conf"
  "${INFRA_DIR}/nginx/api.maintenance.conf"
  "${INFRA_DIR}/docker-compose.nginx.yml"
  "${INFRA_DIR}/docker-compose.redis.yml"
  "${INFRA_DIR}/scripts/nginx-sync.sh"
)

MISSING_FILES=()
for file in "${REQUIRED_FILES[@]}"; do
  if [ ! -f "${file}" ]; then
    MISSING_FILES+=("${file}")
  fi
done

if [ ${#MISSING_FILES[@]} -gt 0 ]; then
  log_error "CRITICAL: Infra repository is incomplete. Missing files:"
  printf '  - %s\n' "${MISSING_FILES[@]}"
  log_error "Ensure ${EXPECTED_INFRA_ROOT} is properly cloned and up to date."
  exit 1
fi
log_ok "Infra repository is complete"

# ---------------------------------------------------------------------------
# Step 3: Ensure all required directories exist and are writable
# ---------------------------------------------------------------------------
log_info "Ensuring required directories exist and are writable..."

REQUIRED_DIRS=(
  "${STATE_DIR}"
  "${LOG_DIR}"
  "${INFRA_DIR}/nginx/live"
  "${INFRA_DIR}/nginx/backup"
)

# /var paths only needed on VPS
if [ "${IS_CI}" != "true" ]; then
  REQUIRED_DIRS+=(
    "/var/www/certbot"
    "/var/log/nginx"
  )
fi

for dir in "${REQUIRED_DIRS[@]}"; do
  ensure_directory_ready "${dir}" || exit 1
done

# ---------------------------------------------------------------------------
# Step 4: Pre-flight binary checks
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

# crontab is only required on VPS (the watchdog does not run in CI)
if [ "${IS_CI}" != "true" ] && ! command -v crontab &>/dev/null; then
  log_error "crontab not found. Install cron before running bootstrap so nginx failover remains protected."
  exit 1
fi

if [ -z "${API_HOSTNAME:-}" ]; then
  log_error "API_HOSTNAME is not set."
  log_error "Export it before running: export API_HOSTNAME=api.example.com"
  exit 1
fi

# TLS is required on VPS; CI provides self-signed certs in a prepare step
if [ "${IS_CI}" != "true" ]; then
  if [ ! -f /etc/ssl/api/origin.crt ] || [ ! -f /etc/ssl/api/origin.key ]; then
    log_error "TLS files are missing."
    log_error "Expected /etc/ssl/api/origin.crt and /etc/ssl/api/origin.key"
    exit 1
  fi
fi

# Confirm nginx-sync can write its log before we invoke it
log_info "Pre-flight: verifying LOG_DIR=${LOG_DIR} is writable for nginx-sync..."
if ! touch "${LOG_DIR}/nginx-sync.log" 2>/dev/null; then
  log_error "Cannot write to ${LOG_DIR}/nginx-sync.log — aborting before nginx-sync"
  exit 1
fi
log_ok "LOG_DIR writable"

log_info "Pre-flight: verifying STATE_DIR=${STATE_DIR} is writable..."
if ! touch "${STATE_DIR}/.write-test" 2>/dev/null; then
  log_error "Cannot write to ${STATE_DIR} — aborting before nginx-sync"
  exit 1
fi
rm -f "${STATE_DIR}/.write-test"
log_ok "STATE_DIR writable"

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

wait_for_redis
validate_redis_network

# ---------------------------------------------------------------------------
# 3. Render nginx config (health-based, no slot arg needed)
# ---------------------------------------------------------------------------
log_info "Syncing nginx (health-based routing)..."

# Export so nginx-sync uses the same paths
export LOG_DIR STATE_DIR

if ! bash "${SCRIPT_DIR}/nginx-sync.sh"; then
  log_error "nginx sync failed during bootstrap."
  exit 1
fi
log_ok "nginx sync completed"

wait_for_nginx() {
  local attempt
  log_info "Waiting for nginx liveness..."
  # shellcheck disable=SC2034
  for attempt in $(seq 1 30); do
    if docker exec nginx sh -eu -c "wget -q --spider --timeout=5 --tries=1 http://127.0.0.1/infra/health" >/dev/null 2>&1; then
      log_ok "nginx ready"
      return 0
    fi
    sleep 1
  done
  log_error "nginx did not become healthy after 30 seconds."
  return 1
}

wait_for_nginx

log_info "Validating host-level nginx /infra/health endpoint..."
if curl -sf http://localhost/infra/health >/dev/null; then
  log_ok "Host-level /infra/health probe passed"
else
  log_error "Host-level /infra/health probe failed."
  exit 1
fi

# ---------------------------------------------------------------------------
# 4. Install nginx watchdog cron (VPS only)
# ---------------------------------------------------------------------------
install_nginx_watchdog() {
  local watchdog_tag="fieldtrack-nginx-watchdog"
  local cron_line
  local existing_cron

  cron_line="* * * * * LOG_DIR='${LOG_DIR}' STATE_DIR='${STATE_DIR}' API_HOSTNAME='${API_HOSTNAME}' bash -lc 'cd \"${INFRA_DIR}\" && if [ -f .env.monitoring ]; then set -a; . ./.env.monitoring; set +a; fi; bash \"${SCRIPT_DIR}/nginx-sync.sh\"' >> \"${INFRA_DIR}/nginx-sync-watchdog.log\" 2>&1 # ${watchdog_tag}"
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

if [ "${IS_CI}" != "true" ]; then
  install_nginx_watchdog
else
  log_info "Skipping watchdog cron install in CI"
fi

# ---------------------------------------------------------------------------
# 5. (Optional) Start monitoring stack — VPS only, requires .env.monitoring
# ---------------------------------------------------------------------------
MONITORING_FAILED=false
if [ "${WITH_MONITORING}" = "true" ]; then
  if [ ! -f "${INFRA_DIR}/.env.monitoring" ]; then
    log_error ".env.monitoring is missing in ${INFRA_DIR}. Required for --with-monitoring."
    exit 1
  fi
  set -a
  # shellcheck source=/dev/null
  source "${INFRA_DIR}/.env.monitoring"
  set +a

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
log_info "  LOG_DIR     : ${LOG_DIR}"
log_info "  STATE_DIR   : ${STATE_DIR}"

if [ "${WITH_MONITORING}" = "false" ]; then
  log_info ""
  log_info "Monitoring was NOT started. To start it later:"
  log_info "  bash scripts/monitoring-sync.sh"
fi

if [ "${MONITORING_FAILED}" = "true" ]; then
  log_warn "Monitoring is optional and remains down. Review scripts/monitoring-sync.sh output."
fi

log_info ""
log_info "Bootstrap complete. System is ready for API deployment."
log_info "Nginx is configured and will serve maintenance mode until first healthy API slot."
