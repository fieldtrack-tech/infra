# FieldTrack Infra

Infrastructure layer for FieldTrack — manages the reverse proxy, cache, and observability stack on the production VPS. Fully independent of the API repository.

---

## Overview

This repository owns everything the API needs to run, but does not own itself:

| Component | Purpose | Required |
|-----------|---------|:--------:|
| **nginx** | Reverse proxy, TLS termination, blue-green routing | ✅ |
| **Redis** | Queue backend + session cache for the API | ✅ |
| **Prometheus** | Metrics scraping from API + host | ❌ |
| **Grafana** | Dashboards and visualization | ❌ |
| **Alertmanager** | Slack alert routing | ❌ |
| **Loki** | Log aggregation | ❌ |
| **Promtail** | Log shipping agent | ❌ |
| **node-exporter** | Host-level metrics | ❌ |

The monitoring stack is **optional** — stopping or removing it has zero effect on API traffic or deployments.

---

## Architecture

### Canonical Path

The infra repository MUST be cloned to `/opt/infra` on production VPS. This is the canonical path that:
- All scripts expect and validate
- The CI deployment workflow uses
- The API repository's deployment scripts reference
- Cron jobs and watchdogs are configured with

Running from a different path will trigger warnings in scripts. For local development and CI testing, scripts will work from any path but will log warnings.

### Network Architecture

```
Internet
    │
    ▼
 nginx (80/443)          ← this repo manages
    │
    ├── api-blue:3000    ← managed by API repo (blue-green slot)
    └── api-green:3000   ← managed by API repo (blue-green slot)

 Redis (redis:6379)      ← this repo manages

 Prometheus              ← optional, this repo manages
 Grafana                 ← optional, this repo manages
 Alertmanager            ← optional, this repo manages
 Loki / Promtail         ← optional, this repo manages

All services share:  api_network (Docker bridge, external)
```

### Network contract

All containers — nginx, Redis, monitoring, and the API's `api-blue`/`api-green` containers — join the `api_network` Docker bridge network. This network is created once by `scripts/bootstrap.sh` and is never removed. The API repo's `deploy.sh` assumes this network already exists.

### Blue-green routing

nginx uses a variable-based proxy (`$api_backend`) resolved at request time via Docker's embedded DNS (`127.0.0.11`). The active slot (`blue` or `green`) is rendered into the nginx config by `scripts/nginx-sync.sh`. The API repo writes the current active slot to `/var/lib/fieldtrack/active-slot` after each deploy; `nginx-sync.sh` reads it for subsequent infra reloads.

---

## Fresh VPS Setup

### Prerequisites

- Docker CE and Docker Compose v2 installed
- SSL certificate and key at `/etc/ssl/api/origin.crt` and `/etc/ssl/api/origin.key`
- `.env.monitoring` created from `.env.monitoring.example` (only needed for monitoring)
- Infra repository cloned to `/opt/infra` (canonical path)

### Steps

```bash
# Clone to canonical path
sudo mkdir -p /opt
sudo chown $USER:$USER /opt
git clone <infra-repo-url> /opt/infra
cd /opt/infra

# Required: set your API hostname
export API_HOSTNAME=api.example.com

# Start core services (Redis + nginx) only:
bash scripts/bootstrap.sh

# Or start core services AND the monitoring stack:
bash scripts/bootstrap.sh --with-monitoring
```

After bootstrap completes, nginx may be serving a maintenance response until the first healthy API slot is deployed. The API repo's first deployment can then run:

```bash
# From the API repo on the VPS (or via CI):
./scripts/deploy.sh <image-sha>
```

### Fresh VPS Validation

After bootstrap on a brand-new VPS, validate the core path explicitly:

```bash
# Redis must be ready inside its own container
docker exec redis redis-cli ping

# Redis must be reachable on the shared Docker network
docker run --rm --network api_network redis:7-alpine redis-cli -h redis ping

# nginx must be alive even before the API exists
curl -kfsS -H "Host: <API_HOSTNAME>" https://127.0.0.1/health

# Before the first API deploy, maintenance mode is expected
curl -ksS -o /dev/null -w "%{http_code}\n" -H "Host: <API_HOSTNAME>" https://127.0.0.1/

# After the first healthy API deploy, both routed checks should succeed
curl -kfsS -H "Host: <API_HOSTNAME>" https://127.0.0.1/health
curl -kfsS -H "Host: <API_HOSTNAME>" https://127.0.0.1/ready
```

---

## Services

### nginx

```bash
# Start / restart
docker compose -f docker-compose.nginx.yml up -d

# Reload config after a slot change
export API_HOSTNAME=api.example.com
bash scripts/nginx-sync.sh
```

nginx reads its runtime config from `nginx/live/api.conf` (rendered by `nginx-sync.sh` from the `nginx/api.conf` template). The `nginx/live/` and `nginx/backup/` directories are not committed — they are runtime artifacts managed by the script.

Advanced options for `nginx-sync.sh`:

- `FIELDTRACK_HEAL_SLOT_ON_FALLBACK=true` lets infra self-heal the durable slot file if the requested slot is unhealthy but the alternate slot is healthy. Leave this unset if you want the API repo to remain the only writer.
- `EXPECTED_DEPLOY_SHA=<sha>` lets infra reject a healthy-but-wrong container version when the API images expose either `org.opencontainers.image.revision` or `com.fieldtrack.deploy-sha`.

### Redis

```bash
# Start / restart
docker compose -f docker-compose.redis.yml up -d
```

Data is persisted to the `redis_data` Docker volume. The API connects to `redis:6379` via `api_network`.

### Monitoring (optional)

```bash
# First: copy and fill the env file
cp .env.monitoring.example .env.monitoring
$EDITOR .env.monitoring

# Start / update
bash scripts/monitoring-sync.sh
```

Grafana is accessible at `https://<API_HOSTNAME>/monitor/` (restricted to Cloudflare IPs and localhost by nginx). The Alertmanager config template at `alertmanager/alertmanager.yml` is rendered by `scripts/render-alertmanager.sh` before each deploy.

---

## Environment

Monitoring stack variables live in `.env.monitoring`. **This file is never committed.** Use `.env.monitoring.example` as the template.

| Variable | Purpose |
|----------|---------|
| `API_HOSTNAME` | Domain nginx is serving (e.g. `api.example.com`) |
| `GRAFANA_ADMIN_PASSWORD` | Grafana admin password |
| `METRICS_SCRAPE_TOKEN` | Bearer token matching `METRICS_SCRAPE_TOKEN` in the API's `.env` |
| `ALERTMANAGER_SLACK_WEBHOOK` | Slack Incoming Webhook URL for alert notifications |

The API's `.env` file is **not used** by this repository.

---

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/bootstrap.sh` | First-time VPS setup — creates `api_network`, starts Redis + nginx |
| `scripts/nginx-sync.sh` | Renders nginx config from template and reloads nginx |
| `scripts/monitoring-sync.sh` | Starts / updates the monitoring stack; never touches API containers |
| `scripts/render-prometheus.sh` | Renders `prometheus.yml` template into `prometheus.rendered.yml` |
| `scripts/render-alertmanager.sh` | Renders `alertmanager.yml` template into `alertmanager.rendered.yml` |
| `scripts/verify-alertmanager.sh` | Smoke-tests Alertmanager health and routing after a config change |
| `scripts/validate-docker-cli.sh` | Validates Docker CLI commands use correct --entrypoint flags |
| `scripts/validate-secrets.sh` | Validates environment variables and secrets configuration |
| `scripts/validate-paths.sh` | Validates infra repository path setup and required directories |

All scripts validate they're running from `/opt/infra` on production and log warnings if not.

---

## CI/CD

The `.github/workflows/infra-deploy.yml` workflow runs on every push to `main`:

1. **validate** — yamllint, compose config validation, shellcheck
2. **deploy** — SSHes into VPS, pulls latest, runs `monitoring-sync.sh` and `nginx-sync.sh`

**What the workflow does NOT do:**
- No API deployment
- No rollback logic
- No dependency on the API repo

Required GitHub Actions secrets:

| Secret | Value |
|--------|-------|
| `VPS_HOST` | VPS IP or hostname |
| `VPS_USER` | SSH username |
| `VPS_SSH_KEY` | Private SSH key (PEM format) |
| `VPS_SSH_PORT` | SSH port (optional, defaults to 22) |

CI mirrors the core production lifecycle closely, but it is not a substitute for host-level smoke checks on the VPS. It cannot fully simulate disk pressure, Docker daemon instability, or real network jitter, so run the Fresh VPS Validation steps after bootstrap and after significant infra changes.

---

## Network Isolation

Stopping or restarting any monitoring container does not interrupt API traffic. The monitoring stack only reads from the API (scraping `/metrics`) — it writes nothing back. nginx and Redis are independent services in separate compose files and separate Docker containers.

To verify isolation:

```bash
# Stop monitoring — nginx and Redis remain up
docker compose -f docker-compose.monitoring.yml down

# Confirm nginx is still serving traffic
curl -sf https://<API_HOSTNAME>/health
```
