#!/usr/bin/env bash
# =============================================================================
# scripts/render-prometheus.sh
#
# Renders prometheus/prometheus.yml into prometheus/prometheus.rendered.yml
# using the values from .env.monitoring.
#
# CANONICAL PATH: /opt/infra
# This script expects to be run from the infra repository root.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Validate we're running from the expected location
EXPECTED_INFRA_ROOT="/opt/infra"
if [ "${INFRA_DIR}" != "${EXPECTED_INFRA_ROOT}" ]; then
  echo "[render-prometheus] WARN  Running from ${INFRA_DIR} instead of ${EXPECTED_INFRA_ROOT}" >&2
fi

ENV_FILE="${INFRA_DIR}/.env.monitoring"
TEMPLATE_FILE="${INFRA_DIR}/prometheus/prometheus.yml"
OUTPUT_FILE="${INFRA_DIR}/prometheus/prometheus.rendered.yml"

log_info()  { printf '[render-prometheus] INFO  %s\n' "$*" >&2; }
log_error() { printf '[render-prometheus] ERROR %s\n' "$*" >&2; }

if ! command -v envsubst &>/dev/null; then
  log_error "envsubst not found. Install gettext (apt install gettext / yum install gettext)."
  exit 1
fi

if [ ! -f "${ENV_FILE}" ]; then
  log_error "Env file not found: ${ENV_FILE}"
  exit 1
fi

if [ ! -f "${TEMPLATE_FILE}" ]; then
  log_error "Template file not found: ${TEMPLATE_FILE}"
  exit 1
fi

set -a
# shellcheck source=/dev/null
source "${ENV_FILE}"
set +a

if [ -z "${API_HOSTNAME:-}" ]; then
  log_error "API_HOSTNAME is not set or empty in ${ENV_FILE}."
  exit 1
fi

if [ -z "${METRICS_SCRAPE_TOKEN:-}" ]; then
  log_error "METRICS_SCRAPE_TOKEN is not set or empty in ${ENV_FILE}."
  exit 1
fi

log_info "Rendering ${TEMPLATE_FILE} -> ${OUTPUT_FILE}"

envsubst '${API_HOSTNAME} ${METRICS_SCRAPE_TOKEN}' \
  < "${TEMPLATE_FILE}" \
  > "${OUTPUT_FILE}"

if grep -q '\${API_HOSTNAME}\|\${METRICS_SCRAPE_TOKEN}' "${OUTPUT_FILE}"; then
  log_error "Rendered Prometheus config still contains unsubstituted placeholders."
  rm -f "${OUTPUT_FILE}"
  exit 1
fi

log_info "Success. Rendered file: ${OUTPUT_FILE}"
