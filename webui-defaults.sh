#!/usr/bin/env bash
#
# webui-defaults.sh - Apply the recommended model defaults to an EXISTING
# Open WebUI install (settings in webui.env only apply on its first start):
#
#   * default model for new chats
#   * built-in tools off for every model (small local models answer with raw
#     JSON such as {"name": "ask_user", ...} when tools are offered)
#
#   ./webui-defaults.sh --model qwen2.5-coder:3b
#
# Asks for the Open WebUI admin email and password (or set WEBUI_ADMIN_EMAIL /
# WEBUI_ADMIN_PASSWORD). Nothing is stored.

set -euo pipefail

URL=""
MODEL=""

die()  { echo "ERROR: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
    cat <<EOF
Usage: $0 [options]

  --model TAG     Default model for new chats (default: keep the current one)
  --url URL       Open WebUI address (default: http://127.0.0.1:<port from webui.env, else 3000>)
  -h, --help      Show this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --model)   MODEL="${2:?}"; shift 2 ;;
        --url)     URL="${2:?}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *)         usage >&2; die "Unknown option: $1" ;;
    esac
done

have curl || die "curl is required."
have python3 || die "python3 is required."

if [ -z "$URL" ]; then
    PORT=$(grep -oP '^PORT=\K[0-9]+' /etc/local-ai-code/webui.env 2>/dev/null || true)
    URL="http://127.0.0.1:${PORT:-3000}"
fi
curl -fsS --max-time 5 "$URL/health" >/dev/null 2>&1 || die "Open WebUI is not reachable at $URL."

EMAIL="${WEBUI_ADMIN_EMAIL:-}"
PASSWORD="${WEBUI_ADMIN_PASSWORD:-}"
[ -n "$EMAIL" ] || read -r -p "Open WebUI admin email: " EMAIL
[ -n "$PASSWORD" ] || { read -r -s -p "Password: " PASSWORD; echo; }

# JSON is built/parsed with python3 so special characters in passwords are safe.
TOKEN=$(EMAIL="$EMAIL" PASSWORD="$PASSWORD" python3 -c '
import json, os
print(json.dumps({"email": os.environ["EMAIL"], "password": os.environ["PASSWORD"]}))' \
    | curl -fsS -X POST "$URL/api/v1/auths/signin" -H 'Content-Type: application/json' -d @- 2>/dev/null \
    | python3 -c 'import json, sys; d = json.load(sys.stdin); print(d["token"] if d.get("role") == "admin" else "")' 2>/dev/null) \
    || die "Sign-in failed: check the email and password."
[ -n "$TOKEN" ] || die "That account is not an admin."

if [ -n "$MODEL" ]; then
    curl -fsS "$URL/api/models" -H "Authorization: Bearer $TOKEN" \
        | MODEL="$MODEL" python3 -c '
import json, os, sys
ids = [m["id"] for m in json.load(sys.stdin)["data"]]
if os.environ["MODEL"] not in ids:
    sys.exit("Model %s is not available. Installed: %s" % (os.environ["MODEL"], ", ".join(ids)))'
fi

curl -fsS "$URL/api/v1/configs/models" -H "Authorization: Bearer $TOKEN" \
    | MODEL="$MODEL" python3 -c '
import json, os, sys
cfg = json.load(sys.stdin)
if os.environ["MODEL"]:
    cfg["DEFAULT_MODELS"] = os.environ["MODEL"]
meta = cfg.get("DEFAULT_MODEL_METADATA") or {}
meta.setdefault("capabilities", {})["builtin_tools"] = False
cfg["DEFAULT_MODEL_METADATA"] = meta
print(json.dumps(cfg))' \
    | curl -fsS -X POST "$URL/api/v1/configs/models" -H "Authorization: Bearer $TOKEN" \
           -H 'Content-Type: application/json' -d @- \
    | python3 -c '
import json, sys
cfg = json.load(sys.stdin)
print("Default model   :", cfg.get("DEFAULT_MODELS") or "<none>")
print("Built-in tools  :", "off" if not (cfg.get("DEFAULT_MODEL_METADATA") or {}).get("capabilities", {}).get("builtin_tools", True) else "on")'

echo "Done. Start a NEW chat in the browser (reload the page) to use the new defaults."
