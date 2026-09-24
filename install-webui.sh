#!/usr/bin/env bash
#
# install-webui.sh - Add a ChatGPT/Claude-style web interface (Open WebUI) in
# front of the local Ollama server, so anyone on the LAN can chat with the
# models from a browser without installing anything.
#
#   sudo ./install-webui.sh                 # http://<server-ip>:3000
#   sudo ./install-webui.sh --port 8080
#
# Open WebUI runs in Docker, keeps chats/users in the 'open-webui' volume and
# talks to Ollama over localhost, so Ollama itself does not need --lan.

set -euo pipefail

PORT=""                          # default: keep the current port, else 3000
IMAGE="ghcr.io/open-webui/open-webui:main"
IMAGE_TAR=""
OLLAMA_URL=""
DEFAULT_MODEL=""
ALLOW_CIDR=""
CONFIGURE_FIREWALL=1
UPGRADE=0
DRY_RUN=0

CONTAINER=open-webui
VOLUME=open-webui
ENV_DIR=/etc/local-ai-code
ENV_FILE="$ENV_DIR/webui.env"
SSH_DIR="$ENV_DIR/ssh"            # set up by install-ssh-tool.sh
SSH_IMAGE="local-ai-code/open-webui-ssh:latest"

if [ -t 1 ]; then
    C_BLUE=$'\e[1;34m'; C_YEL=$'\e[1;33m'; C_RED=$'\e[1;31m'; C_GRN=$'\e[1;32m'; C_OFF=$'\e[0m'
else
    C_BLUE=""; C_YEL=""; C_RED=""; C_GRN=""; C_OFF=""
fi
info()  { echo "${C_BLUE}==>${C_OFF} $*"; }
ok()    { echo "${C_GRN}✔${C_OFF}  $*"; }
warn()  { echo "${C_YEL}!!${C_OFF}  $*" >&2; }
die()   { echo "${C_RED}ERROR:${C_OFF} $*" >&2; exit 1; }
have()  { command -v "$1" >/dev/null 2>&1; }
run()   { if [ "$DRY_RUN" = 1 ]; then echo "   [dry-run] $*"; else "$@"; fi; }

usage() {
    cat <<EOF
Usage: sudo $0 [options]

  --port N             Web UI port (default: current port, else 3000)
  --default-model TAG  Model preselected for new chats (default: best installed Qwen coder)
  --ollama-url URL     Ollama API (default: read from the Ollama service, else http://127.0.0.1:11434)
  --allow CIDR         With ufw active: only allow this subnet (default: local subnet)
  --no-firewall        Do not touch ufw rules
  --image TAG          Container image (default: $IMAGE)
  --image-tar FILE     Load the image from a 'docker save' archive (offline install)
  --upgrade            Pull the latest image and recreate the container (keeps chats/users)
  --dry-run            Print what would be done
  -h, --help           Show this help
EOF
}

ORIG_ARGS=("$@")
while [ $# -gt 0 ]; do
    case "$1" in
        --port)         PORT="${2:?}"; shift 2 ;;
        --ollama-url)   OLLAMA_URL="${2:?}"; shift 2 ;;
        --default-model) DEFAULT_MODEL="${2:?}"; shift 2 ;;
        --allow)        ALLOW_CIDR="${2:?}"; shift 2 ;;
        --no-firewall)  CONFIGURE_FIREWALL=0; shift ;;
        --image)        IMAGE="${2:?}"; shift 2 ;;
        --image-tar)    IMAGE_TAR="${2:?}"; shift 2 ;;
        --upgrade)      UPGRADE=1; shift ;;
        --dry-run)      DRY_RUN=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)              usage >&2; die "Unknown option: $1" ;;
    esac
done
[ -n "$PORT" ] || PORT=$(grep -oP '^PORT=\K[0-9]+' "$ENV_FILE" 2>/dev/null || echo 3000)
[[ "$PORT" =~ ^[0-9]+$ ]] || die "--port must be a number"

if [ "$DRY_RUN" = 0 ] && [ "$(id -u)" -ne 0 ]; then
    have sudo || die "Please run as root."
    exec sudo -E bash "$0" "${ORIG_ARGS[@]}"
fi

# ------------------------------------------------------------------ ollama ---
if [ -z "$OLLAMA_URL" ]; then
    OLLAMA_PORT=$(grep -hoE 'OLLAMA_HOST=[^"]*' /etc/systemd/system/ollama.service.d/*.conf 2>/dev/null \
                  | tail -1 | sed -E 's/.*:([0-9]+)$/\1/' || true)
    OLLAMA_URL="http://127.0.0.1:${OLLAMA_PORT:-11434}"
fi
info "Checking Ollama at $OLLAMA_URL ..."
if ! curl -fsS --max-time 5 "$OLLAMA_URL/api/version" >/dev/null 2>&1; then
    [ "$DRY_RUN" = 1 ] || die "Ollama is not reachable at $OLLAMA_URL. Run ./install.sh first."
fi

# Default model in the UI: as given, else the best installed coder model
# (never a '-base' autocomplete model).
MODELS=$(curl -fsS --max-time 5 "$OLLAMA_URL/api/tags" 2>/dev/null | grep -oE '"name":"[^"]+"' | cut -d'"' -f4 || true)
DEFAULT_MODEL_GIVEN=0
[ -n "$DEFAULT_MODEL" ] && DEFAULT_MODEL_GIVEN=1
# On a re-run keep the previously configured default.
[ -n "$DEFAULT_MODEL" ] || DEFAULT_MODEL=$(grep -oP '^DEFAULT_MODELS=\K.+' "$ENV_FILE" 2>/dev/null || true)
[ -n "$DEFAULT_MODEL" ] || for cand in qwen3-coder:30b qwen2.5-coder:32b qwen2.5-coder:14b qwen2.5-coder:7b \
            qwen2.5-coder:3b qwen2.5-coder:1.5b; do
    if echo "$MODELS" | grep -qxF "$cand"; then DEFAULT_MODEL="$cand"; break; fi
done
[ -n "$DEFAULT_MODEL" ] || DEFAULT_MODEL=$(echo "$MODELS" | grep -v -- '-base' | head -1 || true)
ok "Default model: ${DEFAULT_MODEL:-<none installed yet>}"

# ------------------------------------------------------------------ docker ---
if ! have docker; then
    info "Installing Docker (Ubuntu docker.io package)..."
    run apt-get update -qq
    run apt-get install -y -qq docker.io
fi
run systemctl enable --now docker >/dev/null 2>&1 || true

if [ -n "$IMAGE_TAR" ]; then
    [ -f "$IMAGE_TAR" ] || die "Image archive not found: $IMAGE_TAR"
    info "Loading image from $IMAGE_TAR ..."
    if [[ "$IMAGE_TAR" == *.gz ]]; then
        [ "$DRY_RUN" = 1 ] || gunzip -c "$IMAGE_TAR" | docker load
    else
        run docker load -i "$IMAGE_TAR"
    fi
elif [ "$UPGRADE" = 1 ] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    info "Downloading $IMAGE (about 2 GB compressed, first time only)..."
    run docker pull "$IMAGE"
else
    ok "Image $IMAGE already present (use --upgrade for the latest version)."
fi

# The LAN SSH tool (install-ssh-tool.sh) needs an ssh client in the container:
# layer it on top of the Open WebUI image and mount the key/hosts read-only.
RUN_EXTRA=()
if [ -f "$SSH_DIR/id_ed25519" ]; then
    info "LAN SSH tool is set up: building $SSH_IMAGE (adds openssh-client)..."
    BUILD_ARGS=()
    for v in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY; do
        [ -n "${!v:-}" ] && BUILD_ARGS+=(--build-arg "$v=${!v}")
    done
    if [ "$DRY_RUN" = 1 ]; then
        echo "   [dry-run] docker build -t $SSH_IMAGE (FROM $IMAGE + openssh-client)"
    else
        printf 'FROM %s\nRUN apt-get update && apt-get install -y --no-install-recommends openssh-client && rm -rf /var/lib/apt/lists/*\n' "$IMAGE" \
            | docker build -q --network host "${BUILD_ARGS[@]}" -t "$SSH_IMAGE" - >/dev/null \
            || die "Could not build $SSH_IMAGE (needs internet for the openssh-client package)."
    fi
    IMAGE="$SSH_IMAGE"
    RUN_EXTRA+=(-v "$SSH_DIR:/ssh:ro")
fi

# ------------------------------------------------------------------ config ---
run mkdir -p "$ENV_DIR"
SECRET=""
[ -f "$ENV_FILE" ] && SECRET=$(grep -oP '^WEBUI_SECRET_KEY=\K.*' "$ENV_FILE" || true)
[ -n "$SECRET" ] || SECRET=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 40)

info "Writing $ENV_FILE"
if [ "$DRY_RUN" = 0 ]; then
    ( umask 077; cat > "$ENV_FILE" ) <<EOF
# Managed by local-ai-code/install-webui.sh. Settings marked * are only
# applied on first start; afterwards change them in the UI (Admin Panel).
PORT=$PORT
OLLAMA_BASE_URL=$OLLAMA_URL
WEBUI_SECRET_KEY=$SECRET
# * Model preselected for new chats
DEFAULT_MODELS=$DEFAULT_MODEL
# * The first account becomes admin and Open WebUI then closes sign-up.
#   If the admin re-opens it, new users wait for approval.
DEFAULT_USER_ROLE=pending
ENABLE_EVALUATION_ARENA_MODELS=false
# * No cloud providers, only the local Ollama
ENABLE_OPENAI_API=false
ENABLE_COMMUNITY_SHARING=false
# * On a CPU-only server every extra request slows the chat down, so skip
#   the optional background generations (chat titles are kept).
ENABLE_TAGS_GENERATION=false
ENABLE_FOLLOW_UP_GENERATION=false
ENABLE_AUTOCOMPLETE_GENERATION=false
ENABLE_SEARCH_QUERY_GENERATION=false
ENABLE_RETRIEVAL_QUERY_GENERATION=false
# * Small local models can't use Open WebUI's built-in tools (time, memory,
#   notes, ask_user ...): they reply with raw JSON like {"name": "ask_user", ...}
#   instead of an answer. Turn tools off for every model by default; it can be
#   re-enabled per model in Admin Panel > Settings > Models > Capabilities.
DEFAULT_MODEL_METADATA={"capabilities":{"builtin_tools":false}}
# Fully offline: no update checks, no model downloads, no telemetry
OFFLINE_MODE=true
HF_HUB_OFFLINE=1
ANONYMIZED_TELEMETRY=false
DO_NOT_TRACK=true
SCARF_NO_ANALYTICS=true
EOF
fi

# --------------------------------------------------------------- container ---
# Settings marked * above are stored in the database on first start, so on an
# existing install they must be changed in the Admin Panel instead.
FIRST_START=1
docker volume inspect "$VOLUME" >/dev/null 2>&1 && FIRST_START=0
if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
    info "Replacing existing $CONTAINER container (chats and users are kept)..."
    run docker rm -f "$CONTAINER" >/dev/null
fi
# Host networking lets the container reach Ollama on 127.0.0.1, so Ollama can
# stay private to this machine while only the web UI (which has logins) is exposed.
info "Starting Open WebUI on port $PORT ..."
run docker run -d --name "$CONTAINER" \
    --network host \
    --restart unless-stopped \
    --env-file "$ENV_FILE" \
    -v "$VOLUME:/app/backend/data" \
    "${RUN_EXTRA[@]}" \
    "$IMAGE" >/dev/null

if [ "$DRY_RUN" = 0 ]; then
    info "Waiting for the web UI to start (first start can take a few minutes)..."
    for _ in $(seq 1 300); do
        curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break
        docker container inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true \
            || { docker logs --tail 30 "$CONTAINER" >&2; die "Container exited."; }
        sleep 2
    done
    curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 \
        || die "Web UI did not come up. Check: docker logs $CONTAINER"
    ok "Open WebUI is running."
fi

# ---------------------------------------------------------------- firewall ---
LAN_IP=""
DEF_IF=""
have ip && DEF_IF=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
if [ -n "$DEF_IF" ]; then
    LAN_IP=$(ip -o -4 addr show dev "$DEF_IF" | awk '{split($4,a,"/"); print a[1]; exit}')
    [ -n "$ALLOW_CIDR" ] || ALLOW_CIDR=$(ip -o -4 route show dev "$DEF_IF" scope link proto kernel \
                                          | awk '{print $1; exit}')
fi
[ -n "$LAN_IP" ] || LAN_IP=$(hostname -I 2>/dev/null | awk '{print $1}')

if [ "$CONFIGURE_FIREWALL" = 1 ] && have ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
    [ -n "$ALLOW_CIDR" ] || die "Could not detect LAN subnet; pass --allow CIDR"
    info "ufw is active: allowing $ALLOW_CIDR -> tcp/$PORT"
    run ufw allow from "$ALLOW_CIDR" to any port "$PORT" proto tcp comment 'open-webui (local-ai-code)'
fi

cat <<EOF

${C_GRN}Web UI ready:${C_OFF}  http://${LAN_IP:-localhost}:$PORT

  1. Open that address in a browser on any machine in your network.
  2. Click "Sign up": the FIRST account created becomes the administrator.
  3. Add other people in Admin Panel > Users > "+", or let them register:
     Admin Panel > Settings > General > "Enable New Sign Ups" (you approve them).
  4. Then run ./webui-defaults.sh once: it makes the models visible to the
     other users (Open WebUI keeps them admin-only by default).

EOF
if [ "$FIRST_START" = 0 ] && [ "$DEFAULT_MODEL_GIVEN" = 1 ]; then
    warn "Existing install: model defaults saved in Open WebUI are kept. To apply"
    warn "$DEFAULT_MODEL as default and turn off built-in tools, run:"
    warn "  ./webui-defaults.sh --model $DEFAULT_MODEL"
fi
cat <<EOF

Manage:  docker logs -f $CONTAINER     docker restart $CONTAINER
Upgrade: sudo ./install-webui.sh --upgrade    (chats and users are kept)
EOF
