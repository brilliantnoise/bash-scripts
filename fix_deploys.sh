#!/usr/bin/env bash
set -euo pipefail

# fix_deploys.sh
# Ensures nginx forwards Host header for /_deploy/ and /_github/ locations
# so /opt/deploy-webhooks/server.js can select the correct per-domain hook.
#
# This version is brace-aware and also repairs the common broken shape caused by
# earlier versions: a nested `server {` inside another server block.

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

echo "Patching nginx vhosts in ${NGINX_CONF_DIR} ..."
changed="$(
  python3 - "$NGINX_CONF_DIR" <<'PY'
import glob
import os
import re
import sys

conf_dir = sys.argv[1]
paths = sorted(glob.glob(os.path.join(conf_dir, "*.conf")))

LOC_RE = re.compile(r"^\s*location\s+\^\~\s+(/_deploy/|/_github/)\b")
PROXY_PASS_RE = re.compile(r"proxy_pass\s+[^;]+;")

def brace_delta(line: str) -> int:
    return line.count("{") - line.count("}")

def fix_nested_server(lines):
    # Repair invalid "server {" encountered while already inside a block.
    out = []
    depth = 0
    changed = False
    for ln in lines:
        stripped = ln.lstrip()
        if stripped.startswith("server {") and depth > 0:
            out.append("}\n")
            depth -= 1
            changed = True
        out.append(ln)
        depth += brace_delta(ln)
    return out, changed

def patch_location_block(lines, start, end):
    block = lines[start : end + 1]
    text = "".join(block)

    if "proxy_set_header Host $host;" in text and "proxy_set_header X-Real-IP $remote_addr;" in text:
        return lines, False

    first = block[0]
    indent = re.match(r"^(\s*)", first).group(1)
    inner = indent + "  "

    # Single-line block: rewrite cleanly.
    if start == end:
        m = PROXY_PASS_RE.search(first)
        proxy = m.group(0) if m else "proxy_pass http://127.0.0.1:9000;"
        new_block = [
            first[: first.index("{") + 1] + "\n",
            f"{inner}{proxy}\n",
            f"{inner}proxy_set_header Host $host;\n",
            f"{inner}proxy_set_header X-Real-IP $remote_addr;\n",
            f"{indent}}}\n",
        ]
        return lines[:start] + new_block + lines[end + 1 :], True

    # Multi-line block: insert missing headers before closing brace.
    insert_at = end
    to_add = []
    if "proxy_set_header Host $host;" not in text:
        to_add.append(f"{inner}proxy_set_header Host $host;\n")
    if "proxy_set_header X-Real-IP $remote_addr;" not in text:
        to_add.append(f"{inner}proxy_set_header X-Real-IP $remote_addr;\n")
    if not to_add:
        return lines, False

    new_lines = lines[:insert_at] + to_add + lines[insert_at:]
    return new_lines, True

def patch_file(path):
    with open(path, "r", encoding="utf-8") as f:
        orig = f.readlines()

    lines = orig[:]
    changed = False

    lines, c = fix_nested_server(lines)
    changed = changed or c

    i = 0
    while i < len(lines):
        if not LOC_RE.search(lines[i]):
            i += 1
            continue

        # Find matching closing brace for this location block.
        depth = 0
        start = i
        end = i
        found_open = False
        while end < len(lines):
            delta = brace_delta(lines[end])
            if "{" in lines[end]:
                found_open = True
            depth += delta
            if found_open and depth <= 0:
                break
            end += 1

        if end >= len(lines):
            i += 1
            continue

        lines, c = patch_location_block(lines, start, end)
        changed = changed or c
        i = start + 1

    if changed and lines != orig:
        # Keep a local backup for safety.
        bak = f"{path}.bak.fix_deploys"
        with open(bak, "w", encoding="utf-8") as f:
            f.writelines(orig)
        with open(path, "w", encoding="utf-8") as f:
            f.writelines(lines)
        return True
    return False

changed_files = []
for p in paths:
    try:
        if patch_file(p):
            changed_files.append(p)
    except Exception:
        continue

for p in changed_files:
    print(p)
PY
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

