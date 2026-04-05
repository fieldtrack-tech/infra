#!/usr/bin/env bash
# =============================================================================
# scripts/lib-http.sh
#
# Shared HTTP/HTTPS probe helpers for infra scripts.
# Source this file from any script that needs to probe nginx.
#
# Usage:
#   # shellcheck source=lib-http.sh
#   . "${SCRIPT_DIR}/lib-http.sh"
#
# Requires (checked lazily at each call site, not at source time):
#   API_HOSTNAME   Public hostname served by nginx (no scheme, no trailing slash)
#
# Functions:
#   curl_http_code  URL   — HTTP  status code (3 digits) or "000" on error
#   curl_https_code URL   — HTTPS status code (3 digits) or "000" on error
#   curl_https_body URL   — HTTPS response body or "" on error
# =============================================================================

# ---------------------------------------------------------------------------
# Safety invariants enforced by ALL three helpers:
#
#   --connect-timeout 3
#       Bound the TCP connect phase separately from total transfer time.
#       Without this, a hung kernel accept queue consumes the entire
#       --max-time budget before curl even sends the first byte.
#
#   --max-time 5
#       Hard cap on total elapsed time (DNS + connect + TLS + transfer).
#
#   --max-redirs 0
#       Redirects (3xx) are treated as non-successful probes.
#       `curl -f / --fail` only exits non-zero for HTTP 400+; a 301 from a
#       misconfigured nginx block (e.g. /infra/health missing, falling
#       through to `location / { return 301 ... }`) exits 0 with -f and
#       silently masks a broken state.  With --max-redirs 0, curl exits
#       non-zero (CURLE_TOO_MANY_REDIRECTS) on any redirect; the
#       `|| echo "000"` sentinel ensures the caller always receives
#       exactly 3 printable digits and never an empty string.
#
#   API_HOSTNAME guard
#       Each function asserts API_HOSTNAME is non-empty at call time.
#       This fires with a clear error under `set -euo pipefail` if the
#       caller forgot to export the variable.
# ---------------------------------------------------------------------------

# curl_http_code URL
#
# Emits the HTTP status code for a plain-HTTP GET, or "000" on error.
#
# Additional constraint:
#   -H "Host: ${API_HOSTNAME}"
#       Required so nginx routes the request to the correct server block.
#       Without it, a bare http://127.0.0.1 request may not match the
#       expected server_name and hit a catch-all block that returns 301.
#
curl_http_code() {
  local url="$1"
  : "${API_HOSTNAME:?curl_http_code: API_HOSTNAME must be set}"
  curl -s -o /dev/null -w "%{http_code}" \
    --max-time 5 \
    --connect-timeout 3 \
    --max-redirs 0 \
    -H "Host: ${API_HOSTNAME}" \
    "${url}" 2>/dev/null || echo "000"
}

# curl_https_code URL
#
# Emits the HTTPS status code for a GET to URL, or "000" on error.
#
# Additional constraints:
#   --resolve "${API_HOSTNAME}:443:127.0.0.1"
#       Routes the TCP connection to 127.0.0.1 while sending the correct
#       SNI and Host header so nginx matches the right server block.
#       This is strictly better than `https://127.0.0.1` with a Host header
#       because it also sets the correct TLS SNI extension.
#
#   -k  Skip certificate verification.
#       Self-signed certs are used in CI and on VPS before Let's Encrypt
#       is provisioned.  SNI correctness is still enforced via --resolve.
#
curl_https_code() {
  local url="$1"
  : "${API_HOSTNAME:?curl_https_code: API_HOSTNAME must be set}"
  curl -s -o /dev/null -w "%{http_code}" \
    --max-time 5 \
    --connect-timeout 3 \
    --max-redirs 0 \
    -k \
    --resolve "${API_HOSTNAME}:443:127.0.0.1" \
    "${url}" 2>/dev/null || echo "000"
}

# curl_https_body URL
#
# Emits the HTTPS response body for a GET to URL, or "" on error.
# Same connection parameters as curl_https_code.
# `curl -s` emits the body even for non-2xx responses, which is required
# for checking maintenance-mode payloads that arrive as HTTP 503.
#
curl_https_body() {
  local url="$1"
  : "${API_HOSTNAME:?curl_https_body: API_HOSTNAME must be set}"
  curl -s \
    --max-time 5 \
    --connect-timeout 3 \
    --max-redirs 0 \
    -k \
    --resolve "${API_HOSTNAME}:443:127.0.0.1" \
    "${url}" 2>/dev/null || echo ""
}
