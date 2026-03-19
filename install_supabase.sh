#!/usr/bin/env bash
# install_supabase.sh — Self-hosted Supabase (official Docker Compose) with localhost-bound ports.
#
# Usage:
#   sudo ./install_supabase.sh <PUBLIC_BASE_URL>
#   sudo PUBLIC_BASE_URL=https://app.example.com ./install_supabase.sh
#
# PUBLIC_BASE_URL must be the HTTPS origin where API paths (/auth/v1, /rest/v1, …) are served
# (typically the same host as your app, after add_supabase_to_app.sh adds nginx routes).
#
# Optional env:
#   SUPABASE_DOCKER_DIR=/opt/supabase/docker   (install location)
#   SUPABASE_GIT_REF=master                    (git ref for shallow clone)
#   KONG_HTTP_PORT=8000                        (must match nginx snippet from add_supabase_to_app.sh)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPABASE_DOCKER_DIR="${SUPABASE_DOCKER_DIR:-/opt/supabase/docker}"
SUPABASE_GIT_REF="${SUPABASE_GIT_REF:-master}"
SUPABASE_REPO="${SUPABASE_REPO:-https://github.com/supabase/supabase.git}"
KONG_HTTP_PORT="${KONG_HTTP_PORT:-8000}"
KONG_HTTPS_PORT="${KONG_HTTPS_PORT:-8443}"

PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-${1:-}}"
strip_trailing_slash() { local s="$1"; s="${s%/}"; echo "$s"; }
PUBLIC_BASE_URL="$(strip_trailing_slash "${PUBLIC_BASE_URL}")"

if [[ $EUID -ne 0 ]]; then echo "Run as root (sudo)"; exit 1; fi

if [[ -z "${PUBLIC_BASE_URL}" ]]; then
  echo "Usage: sudo $0 <PUBLIC_BASE_URL>"
  echo "Example: sudo $0 https://app.example.com"
  exit 1
fi

if [[ "${PUBLIC_BASE_URL}" != http://* && "${PUBLIC_BASE_URL}" != https://* ]]; then
  echo "PUBLIC_BASE_URL must start with http:// or https:// (got: ${PUBLIC_BASE_URL})"
  exit 1
fi

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1"; exit 1; }; }

ensure_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    return 0
  fi
  echo "Installing Docker Engine and compose plugin (apt)..."
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl git openssl
  # Docker official repo (works on supported Ubuntu/Debian)
  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc 2>/dev/null || true
  fi
  if [[ -f /etc/apt/keyrings/docker.asc ]]; then
    chmod a+r /etc/apt/keyrings/docker.asc
    . /etc/os-release
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME:-jammy} stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  else
    DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io docker-compose-v2 || {
      DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io
    }
  fi
  systemctl enable --now docker 2>/dev/null || true
  need_cmd docker
  docker compose version >/dev/null 2>&1 || { echo "docker compose plugin missing"; exit 1; }
}

patch_compose_localhost_ports() {
  local compose="${SUPABASE_DOCKER_DIR}/docker-compose.yml"
  [[ -f "$compose" ]] || return 1
  if grep -q '127.0.0.1:.*:8000/tcp' "$compose" 2>/dev/null; then
    return 0
  fi
  cp -a "${compose}" "${compose}.bak.$(date +%Y%m%d%H%M%S)"
  # Compose file uses literal ${VAR} placeholders; substitute host port numbers from .env
  sed -i \
    -e 's|- ${KONG_HTTP_PORT}:8000/tcp|- "127.0.0.1:'"${KONG_HTTP_PORT}"':8000/tcp"|g' \
    -e 's|- ${KONG_HTTPS_PORT}:8443/tcp|- "127.0.0.1:'"${KONG_HTTPS_PORT}"':8443/tcp"|g' \
    -e 's|- ${POSTGRES_PORT}:5432|- "127.0.0.1:'"${POSTGRES_PORT}"':5432"|g' \
    -e 's|- ${POOLER_PROXY_PORT_TRANSACTION}:6543|- "127.0.0.1:'"${POOLER_PROXY_PORT_TRANSACTION}"':6543"|g' \
    "$compose"
}

# Logflare (supabase-analytics) often needs >60s on first boot for Postgres migrations; upstream
# healthcheck (10×5s) marks the container unhealthy too soon → studio/kong never start.
# docker-compose.override.yml is merged automatically by `docker compose`.
write_compose_override_analytics() {
  cat > "${SUPABASE_DOCKER_DIR}/docker-compose.override.yml" <<'YAML'
# Managed by install_supabase.sh — do not remove unless you know why it is here.
services:
  analytics:
    healthcheck:
      test: ["CMD", "curl", "http://localhost:4000/health"]
      interval: 10s
      timeout: 10s
      retries: 45
      start_period: 180s
YAML
}

ensure_docker
need_cmd git
need_cmd openssl

mkdir -p "${SUPABASE_DOCKER_DIR}"

if [[ ! -f "${SUPABASE_DOCKER_DIR}/docker-compose.yml" ]]; then
  echo "Fetching Supabase Docker stack (ref: ${SUPABASE_GIT_REF})..."
  tmp="$(mktemp -d)"
  git clone --depth 1 --branch "${SUPABASE_GIT_REF}" "${SUPABASE_REPO}" "${tmp}/supabase"
  cp -a "${tmp}/supabase/docker/." "${SUPABASE_DOCKER_DIR}/"
  rm -rf "${tmp}"
fi

cd "${SUPABASE_DOCKER_DIR}"

# Upstream tracks .sh as non-executable; git checkouts are often mode 644 — use -f not -x.
if [[ ! -f ./utils/generate-keys.sh ]]; then
  echo "docker/utils missing (incomplete copy); fetching utils only..."
  tmp="$(mktemp -d)"
  git clone --depth 1 --branch "${SUPABASE_GIT_REF}" "${SUPABASE_REPO}" "${tmp}/supabase"
  cp -a "${tmp}/supabase/docker/utils" "${SUPABASE_DOCKER_DIR}/"
  rm -rf "${tmp}"
fi
chmod +x ./utils/*.sh 2>/dev/null || true

ENV_NEW=false
if [[ ! -f .env ]]; then
  cp -a .env.example .env
  ENV_NEW=true
fi

if [[ -f ./utils/generate-keys.sh ]]; then
  if [[ "${ENV_NEW}" == true ]] || grep -q '^JWT_SECRET=your-super-secret-jwt-token' .env 2>/dev/null; then
    echo "Generating secrets (JWT, DB password, keys)..."
    sh ./utils/generate-keys.sh --update-env
  else
    echo "Using existing .env secrets (not re-running generate-keys.sh — avoids breaking an initialized database)."
  fi
else
  echo "ERROR: utils/generate-keys.sh still missing under ${SUPABASE_DOCKER_DIR}"
  exit 1
fi

# Pooler tenant id must be unique (not left as placeholder)
if grep -q '^POOLER_TENANT_ID=your-tenant-id' .env; then
  sed -i "s/^POOLER_TENANT_ID=.*/POOLER_TENANT_ID=$(openssl rand -hex 8)/" .env
fi

# Public URLs for Auth redirects, Storage, Studio (same origin as nginx-served API paths)
sed -i \
  -e "s|^SUPABASE_PUBLIC_URL=.*|SUPABASE_PUBLIC_URL=${PUBLIC_BASE_URL}|" \
  -e "s|^API_EXTERNAL_URL=.*|API_EXTERNAL_URL=${PUBLIC_BASE_URL}|" \
  -e "s|^SITE_URL=.*|SITE_URL=${PUBLIC_BASE_URL}|" \
  .env

# Kong / pooler ports (exported for compose + our sed patch)
grep -q '^KONG_HTTP_PORT=' .env && sed -i "s/^KONG_HTTP_PORT=.*/KONG_HTTP_PORT=${KONG_HTTP_PORT}/" .env || echo "KONG_HTTP_PORT=${KONG_HTTP_PORT}" >> .env
grep -q '^KONG_HTTPS_PORT=' .env && sed -i "s/^KONG_HTTPS_PORT=.*/KONG_HTTPS_PORT=${KONG_HTTPS_PORT}/" .env || echo "KONG_HTTPS_PORT=${KONG_HTTPS_PORT}" >> .env

POSTGRES_PORT="$(grep -E '^POSTGRES_PORT=' .env | cut -d= -f2- | tr -d '\r' || true)"
POOLER_PROXY_PORT_TRANSACTION="$(grep -E '^POOLER_PROXY_PORT_TRANSACTION=' .env | cut -d= -f2- | tr -d '\r' || true)"
: "${POSTGRES_PORT:=5432}"
: "${POOLER_PROXY_PORT_TRANSACTION:=6543}"
export KONG_HTTP_PORT KONG_HTTPS_PORT POSTGRES_PORT POOLER_PROXY_PORT_TRANSACTION

patch_compose_localhost_ports
write_compose_override_analytics

echo "Pulling images and starting stack (first start may take several minutes)..."
docker compose pull
if ! docker compose up -d; then
  echo ""
  echo "❌ docker compose up failed. If supabase-analytics was unhealthy, check:"
  echo "   sudo docker logs supabase-analytics"
  echo "   (Small instances: Logflare may need more RAM; errors often show migration/schema issues.)"
  exit 1
fi

# Marker for companion scripts
{
  echo "installed_at=$(date -Iseconds)"
  echo "public_base_url=${PUBLIC_BASE_URL}"
  echo "kong_http_port=${KONG_HTTP_PORT}"
} > "${SUPABASE_DOCKER_DIR}/.bash-scripts-install"
chmod 0644 "${SUPABASE_DOCKER_DIR}/.bash-scripts-install"

echo ""
echo "=========================================="
echo "Supabase Docker stack is up."
echo "=========================================="
echo "Install dir:     ${SUPABASE_DOCKER_DIR}"
echo "Public API URL:  ${PUBLIC_BASE_URL}"
echo "App env:         NEXT_PUBLIC_SUPABASE_URL=${PUBLIC_BASE_URL}"
echo "Kong (local):    127.0.0.1:${KONG_HTTP_PORT}"
echo ""
echo "Keys (also in ${SUPABASE_DOCKER_DIR}/.env):"
grep -E '^(ANON_KEY|SERVICE_ROLE_KEY)=' .env | sed 's/=.*/=***redacted***/'
echo ""
echo "Show keys:  sudo grep -E '^(ANON_KEY|SERVICE_ROLE_KEY)=' ${SUPABASE_DOCKER_DIR}/.env"
echo ""
echo "Next: run add_supabase_to_app.sh on each nginx vhost that should proxy /auth/v1, /rest/v1, …"
echo "=========================================="
