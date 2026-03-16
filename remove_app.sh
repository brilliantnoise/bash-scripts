#!/usr/bin/env bash
set -euo pipefail
trap 'echo "❌ ERROR on line $LINENO (exit code $?)" >&2' ERR

# ===========================================
# remove_app.sh
# - Completely removes a Node app from the server
# - Removes PM2 processes, Nginx configs, TLS certs,
#   webhook entries, deploy keys, and app directories
# ===========================================

WWW_ROOT="/var/www"
NGINX_CONF_DIR="/etc/nginx/conf.d"
WEBHOOK_DIR="/opt/deploy-webhooks"

GIT_USER="gitdeploy"
APP_USER="${SUDO_USER:-$(id -un)}"
GIT_HOME="/home/${GIT_USER}"
SSH_DIR="${GIT_HOME}/.ssh"
SSH_CONFIG="${SSH_DIR}/config"

# ---- preflight ----
if [[ $EUID -ne 0 ]]; then
  echo "Run as root (sudo)"
  exit 1
fi

# ---- Input ----
read -rp "App name to remove (e.g., myapp): " APP_NAME
[[ -z "${APP_NAME}" ]] && { echo "App name is required."; exit 1; }

APP_DIR_ROOT="${WWW_ROOT}/${APP_NAME}"

if [[ ! -d "${APP_DIR_ROOT}" ]]; then
  echo "WARNING: App directory ${APP_DIR_ROOT} does not exist."
fi

# Collect domains from existing Nginx configs so we know what to clean up
DOMAINS=()
for env_suffix in live dev staging; do
  pm2_name="${APP_NAME}-${env_suffix}"
  for conf in "${NGINX_CONF_DIR}"/*.conf; do
    [[ -f "${conf}" ]] || continue
    if grep -q "proxy_pass.*127.0.0.1" "${conf}" 2>/dev/null; then
      domain="$(basename "${conf}" .conf)"
      app_dir="${APP_DIR_ROOT}/${env_suffix}"
      if [[ -d "${app_dir}" ]] && grep -q "${app_dir}" "${conf}" 2>/dev/null; then
        DOMAINS+=("${domain}")
      fi
    fi
  done
done

# Also try matching by the PM2 ecosystem files to find port → nginx config mappings
for env_suffix in live dev staging; do
  eco_file="${APP_DIR_ROOT}/${env_suffix}/ecosystem.config.cjs"
  if [[ -f "${eco_file}" ]]; then
    port="$(grep -oP 'PORT:\s*"\K[0-9]+' "${eco_file}" 2>/dev/null || true)"
    if [[ -n "${port}" ]]; then
      for conf in "${NGINX_CONF_DIR}"/*.conf; do
        [[ -f "${conf}" ]] || continue
        if grep -q "127.0.0.1:${port}" "${conf}" 2>/dev/null; then
          domain="$(basename "${conf}" .conf)"
          # Avoid duplicates
          if [[ ! " ${DOMAINS[*]:-} " =~ " ${domain} " ]]; then
            DOMAINS+=("${domain}")
          fi
        fi
      done
    fi
  fi
done

echo ""
echo "================================================================"
echo "⚠️  REMOVAL SUMMARY FOR: ${APP_NAME}"
echo "================================================================"
echo ""
echo "The following will be removed:"
echo "  • PM2 processes: ${APP_NAME}-live, ${APP_NAME}-dev, ${APP_NAME}-staging"
echo "  • App directory: ${APP_DIR_ROOT}"
if [[ ${#DOMAINS[@]} -gt 0 ]]; then
  echo "  • Nginx configs: ${DOMAINS[*]}"
  echo "  • TLS certificates for above domains"
fi
echo "  • SSH deploy key: ${SSH_DIR}/deploykey_${APP_NAME}"
echo "  • SSH config entry for ${APP_NAME}-github"
echo "  • Webhook entries in hooks.json"
echo ""
read -rp "Type '${APP_NAME}' to confirm removal: " CONFIRM
[[ "${CONFIRM}" != "${APP_NAME}" ]] && { echo "Aborted."; exit 1; }
echo ""

# ---- 1. Stop and remove PM2 processes ----
echo "🔄 Stopping PM2 processes..."
for env_suffix in live dev staging; do
  pm2_name="${APP_NAME}-${env_suffix}"
  sudo -u "${APP_USER}" bash -lc '
    export NVM_DIR=$HOME/.nvm; . "$NVM_DIR/nvm.sh"
    pm2 delete "'"${pm2_name}"'" 2>/dev/null && echo "  ✓ Removed PM2 process: '"${pm2_name}"'" || echo "  - PM2 process '"${pm2_name}"' not found (skipped)"
  ' || true
done
sudo -u "${APP_USER}" bash -lc '
  export NVM_DIR=$HOME/.nvm; . "$NVM_DIR/nvm.sh"
  pm2 save
' || true
echo ""

# ---- 2. Remove Nginx configs ----
echo "🔄 Removing Nginx configurations..."
for domain in "${DOMAINS[@]:-}"; do
  [[ -z "${domain}" ]] && continue
  conf_file="${NGINX_CONF_DIR}/${domain}.conf"
  if [[ -f "${conf_file}" ]]; then
    rm -f "${conf_file}"
    echo "  ✓ Removed ${conf_file}"
  fi
done
if nginx -t 2>/dev/null; then
  systemctl reload nginx
  echo "  ✓ Nginx reloaded"
else
  echo "  ⚠️  Nginx config test failed — check manually"
fi
echo ""

# ---- 3. Revoke and delete TLS certificates ----
echo "🔄 Removing TLS certificates..."
for domain in "${DOMAINS[@]:-}"; do
  [[ -z "${domain}" ]] && continue
  if certbot certificates -d "${domain}" 2>/dev/null | grep -q "Certificate Name"; then
    certbot delete --cert-name "${domain}" --non-interactive 2>/dev/null \
      && echo "  ✓ Removed certificate for ${domain}" \
      || echo "  ⚠️  Could not remove certificate for ${domain}"
  else
    echo "  - No certificate found for ${domain} (skipped)"
  fi
done
echo ""

# ---- 4. Remove webhook entries from hooks.json ----
echo "🔄 Removing webhook entries..."
HOOKS_FILE="${WEBHOOK_DIR}/hooks.json"
if [[ -f "${HOOKS_FILE}" ]]; then
  python3 - "${HOOKS_FILE}" "${APP_NAME}" <<'PY'
import json, sys

cfg_path, app_name = sys.argv[1], sys.argv[2]

with open(cfg_path, 'r', encoding='utf-8') as f:
    cfg = json.load(f)

hook_ids = {f"{app_name}-live", f"{app_name}-dev", f"{app_name}-staging"}
before = len(cfg.get("hooks", []))
cfg["hooks"] = [h for h in cfg.get("hooks", []) if h.get("id") not in hook_ids]
removed_hooks = before - len(cfg["hooks"])

before_gh = len(cfg.get("github", []))
cfg["github"] = [g for g in cfg.get("github", []) if g.get("id") != app_name]
removed_gh = before_gh - len(cfg["github"])

with open(cfg_path, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, indent=2)

print(f"  ✓ Removed {removed_hooks} hook(s) and {removed_gh} GitHub mapping(s)")
PY
  # Restart webhook server to pick up changes
  sudo -u "${APP_USER}" bash -lc '
    export NVM_DIR=$HOME/.nvm; . "$NVM_DIR/nvm.sh"
    pm2 restart deploy-webhooks 2>/dev/null || true
    pm2 save || true
  ' || true
else
  echo "  - hooks.json not found (skipped)"
fi
echo ""

# ---- 5. Remove SSH deploy key and config entry ----
echo "🔄 Removing SSH deploy key..."
KEY_PATH="${SSH_DIR}/deploykey_${APP_NAME}"
rm -f "${KEY_PATH}" "${KEY_PATH}.pub"
[[ ! -f "${KEY_PATH}" ]] && echo "  ✓ Removed deploy key files" || echo "  - No deploy key found (skipped)"

if [[ -f "${SSH_CONFIG}" ]] && grep -q "# Deploy key for ${APP_NAME}" "${SSH_CONFIG}"; then
  sudo -u "${GIT_USER}" sed -i.bak "/# Deploy key for ${APP_NAME}/,/^$/d" "${SSH_CONFIG}"
  rm -f "${SSH_CONFIG}.bak"
  echo "  ✓ Removed SSH config entry for ${APP_NAME}-github"
else
  echo "  - No SSH config entry found (skipped)"
fi
echo ""

# ---- 6. Remove app directories ----
echo "🔄 Removing app directory..."
if [[ -d "${APP_DIR_ROOT}" ]]; then
  rm -rf "${APP_DIR_ROOT}"
  echo "  ✓ Removed ${APP_DIR_ROOT}"
else
  echo "  - ${APP_DIR_ROOT} not found (skipped)"
fi
echo ""

echo "========================================================"
echo "✓ App '${APP_NAME}' has been completely removed."
echo ""
echo "Note: Remote GitHub branches (dev, staging) were NOT deleted."
echo "      Remove the deploy key from GitHub repo settings manually."
echo "========================================================"
