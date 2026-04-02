#!/usr/bin/env bash
set -euo pipefail

# fix_deploys.sh
# Ensures nginx forwards Host header for /_deploy/ and /_github/ locations
# so /opt/deploy-webhooks/server.js can select the correct per-domain hook.

NGINX_CONF_DIR="/etc/nginx/conf.d"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root (sudo)."
  exit 1
fi

if [[ ! -d "$NGINX_CONF_DIR" ]]; then
  echo "Nginx conf dir not found: $NGINX_CONF_DIR"
  exit 1
fi

if ! command -v nginx >/dev/null 2>&1; then
  echo "nginx binary not found on PATH."
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required."
  exit 1
fi

PY="$(cat <<'PY'
import glob
import os
import re
import sys

conf_dir = sys.argv[1]
paths = sorted(glob.glob(os.path.join(conf_dir, "*.conf")))

def patch_locations(text: str, loc: str) -> tuple[str, bool]:
    """
    For a given location prefix (e.g. "/_deploy/"), ensure:
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
    inside the matching `location ^~ <loc> { ... }` block.
    """
    changed = False

    # Find blocks like: location ^~ /_deploy/ { ... }
    # Capture indent so we can keep formatting consistent.
    pat = re.compile(
        r'(?P<indent>^[ \t]*)location\s+\^\~\s+'
        + re.escape(loc)
        + r'\s*\{(?P<body>[\s\S]*?)^\s*\}',
        re.MULTILINE,
    )

    def repl(m: re.Match) -> str:
        nonlocal changed
        indent = m.group("indent")
        body = m.group("body")

        # Normalize body lines for easy checks (but preserve original when possible)
        has_host = re.search(r'^\s*proxy_set_header\s+Host\s+\$host\s*;', body, re.MULTILINE) is not None
        has_realip = re.search(r'^\s*proxy_set_header\s+X-Real-IP\s+\$remote_addr\s*;', body, re.MULTILINE) is not None

        if has_host and has_realip:
            return m.group(0)

        # If this is the single-line style `location ... { proxy_pass ...; }`,
        # `body` will contain that inline directive.
        # We'll rewrite the whole block cleanly, preserving the proxy_pass line.
        proxy_pass_m = re.search(r'proxy_pass\s+[^;]+;', body)
        proxy_pass = proxy_pass_m.group(0).strip() if proxy_pass_m else None

        inner = indent + "  "
        lines = []
        if proxy_pass:
            lines.append(f"{inner}{proxy_pass}")
        else:
            # No proxy_pass found; keep original body and just inject missing headers after opening brace.
            # This is conservative and avoids breaking unusual configs.
            injected = body
            # Inject Host then X-Real-IP at top of body.
            inserts = []
            if not has_host:
                inserts.append(f"{inner}proxy_set_header Host $host;")
            if not has_realip:
                inserts.append(f"{inner}proxy_set_header X-Real-IP $remote_addr;")
            new_body = "\n" + "\n".join(inserts) + injected
            changed = True
            return f"{indent}location ^~ {loc} {{{new_body}\n{indent}}}"

        if not has_host:
            lines.append(f"{inner}proxy_set_header Host $host;")
        if not has_realip:
            lines.append(f"{inner}proxy_set_header X-Real-IP $remote_addr;")

        changed = True
        return f"{indent}location ^~ {loc} {{\n" + "\n".join(lines) + f"\n{indent}}}"

    new_text = pat.sub(repl, text)
    return new_text, changed

changed_files = []
for p in paths:
    try:
        with open(p, "r", encoding="utf-8") as f:
            orig = f.read()
    except Exception:
        continue

    text = orig
    changed = False
    for loc in ("/_deploy/", "/_github/"):
        text, c = patch_locations(text, loc)
        changed = changed or c

    if changed and text != orig:
        with open(p, "w", encoding="utf-8") as f:
            f.write(text)
        changed_files.append(p)

for p in changed_files:
    print(p)
PY
)"

echo "Patching nginx vhosts in ${NGINX_CONF_DIR} ..."
changed="$(
  python3 -c "$PY" "$NGINX_CONF_DIR" || true
)"

if [[ -n "${changed}" ]]; then
  echo "Updated:"
  echo "${changed}" | sed 's/^/  - /'
else
  echo "No changes needed."
fi

echo "Validating nginx config..."
nginx -t

echo "Reloading nginx..."
systemctl reload nginx

echo "Done."

