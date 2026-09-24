#!/usr/bin/env bash
#
# install-ssh-tool.sh - Let the web chat run commands on Linux machines in the
# LAN over SSH ("LAN Assistant" model, admin account only).
#
#   sudo ./install-ssh-tool.sh --add-host me@192.168.1.20 --alias nas
#   sudo ./install-ssh-tool.sh --add-host admin@web01
#   sudo ./install-ssh-tool.sh --list
#   sudo ./install-ssh-tool.sh --remove-host 192.168.1.20
#
# Read-only commands (df, free, systemctl status, journalctl ...) run directly.
# Anything that may change a machine pops up an approval dialog in the chat.
# Requires install.sh --webui (or install-webui.sh) to have been run first.

set -euo pipefail

MODEL="qwen3:8b"
ADD_HOSTS=()
ALIASES=()
REMOVE_HOSTS=()
LIST=0
FORCE_SETUP=0

SCRIPT_DIR=$(cd "$(dirname "$(realpath "$0")")" && pwd)
ENV_DIR=/etc/local-ai-code
SSH_DIR="$ENV_DIR/ssh"
KEY="$SSH_DIR/id_ed25519"
HOSTS="$SSH_DIR/hosts"
KNOWN="$SSH_DIR/known_hosts"
MARKER="$SSH_DIR/.installed"

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

usage() {
    cat <<EOF
Usage: sudo $0 [options]

  --add-host USER@HOST   Allow the assistant to reach HOST as USER (repeatable).
                         Asks for USER's password once to install the SSH key.
  --alias NAME           Friendly name for the preceding --add-host (e.g. nas)
  --remove-host HOST     Remove a host (and its recorded host key)
  --list                 Show registered hosts and the public key
  --model TAG            Tool-capable model for "LAN Assistant" (default: $MODEL)
  --setup                Re-run the full setup (image, model, registration)
  -h, --help             Show this help
EOF
}

ORIG_ARGS=("$@")
while [ $# -gt 0 ]; do
    case "$1" in
        --add-host)    ADD_HOSTS+=("${2:?}"); ALIASES+=(""); shift 2 ;;
        --alias)       [ ${#ADD_HOSTS[@]} -gt 0 ] || die "--alias must follow --add-host"
                       ALIASES[${#ALIASES[@]}-1]="${2:?}"; shift 2 ;;
        --remove-host) REMOVE_HOSTS+=("${2:?}"); shift 2 ;;
        --list)        LIST=1; shift ;;
        --model)       MODEL="${2:?}"; FORCE_SETUP=1; shift 2 ;;
        --setup)       FORCE_SETUP=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             usage >&2; die "Unknown option: $1" ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    have sudo || die "Please run as root."
    exec sudo -E bash "$0" "${ORIG_ARGS[@]}"
fi
if ! have ssh-keygen || ! have ssh-copy-id; then
    die "openssh-client is required (apt-get install openssh-client)."
fi

SSH_OPTS=(-i "$KEY" -o "UserKnownHostsFile=$KNOWN" -o ConnectTimeout=10)

# ------------------------------------------------------------------- key ---
install -d -m 700 "$SSH_DIR"
touch "$HOSTS" "$KNOWN"
chmod 600 "$KNOWN"; chmod 644 "$HOSTS"
if [ ! -f "$KEY" ]; then
    info "Creating the assistant's SSH key $KEY"
    ssh-keygen -q -t ed25519 -N "" -C "local-ai-code@$(hostname)" -f "$KEY"
fi

# ----------------------------------------------------------------- hosts ---
for h in "${REMOVE_HOSTS[@]}"; do
    name="${h#*@}"
    if grep -qE "^[^#[:space:]]*@${name//./\\.}([[:space:]]|$)" "$HOSTS"; then
        sed -i -E "/^[^#[:space:]]*@${name//./\\.}([[:space:]]|$)/d" "$HOSTS"
        ssh-keygen -q -R "$name" -f "$KNOWN" >/dev/null 2>&1 || true
        rm -f "$KNOWN.old"
        ok "Removed $name. Its authorized_keys still has the key: remove the line"
        echo "   ending in 'local-ai-code@$(hostname)' from ~/.ssh/authorized_keys on $name."
    else
        warn "$name is not registered."
    fi
done

for i in "${!ADD_HOSTS[@]}"; do
    target="${ADD_HOSTS[$i]}"; alias="${ALIASES[$i]}"
    [[ "$target" == *@* ]] || die "Use USER@HOST for --add-host (got '$target')."
    name="${target#*@}"
    info "Installing the assistant's key on $target (enter $target's password if asked)..."
    ssh-copy-id -i "$KEY.pub" -o "UserKnownHostsFile=$KNOWN" -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=10 "$target" \
        || die "Could not copy the key to $target. Check the address, user and that sshd runs there."
    ssh "${SSH_OPTS[@]}" -o BatchMode=yes -o StrictHostKeyChecking=yes "$target" true \
        || die "Key login to $target does not work."
    sed -i -E "/^[^#[:space:]]*@${name//./\\.}([[:space:]]|$)/d" "$HOSTS"
    echo "$target${alias:+ $alias}" >> "$HOSTS"
    ok "Added $target${alias:+ (alias: $alias)}"
done

if [ "$LIST" = 1 ]; then
    echo "Registered hosts ($HOSTS):"
    grep -vE '^\s*(#|$)' "$HOSTS" | sed 's/^/  /' || echo "  (none)"
    echo
    echo "Public key (add it to ~/.ssh/authorized_keys on a host to allow it manually):"
    echo "  $(cat "$KEY.pub")"
fi

# Adding/removing hosts on an existing setup takes effect immediately.
if [ -f "$MARKER" ] && [ "$FORCE_SETUP" = 0 ]; then
    exit 0
fi
if [ ${#ADD_HOSTS[@]} -eq 0 ] && [ ! -f "$MARKER" ] && ! grep -qvE '^\s*(#|$)' "$HOSTS"; then
    warn "No hosts registered yet: the assistant will have nothing to connect to."
    warn "Add one with: sudo $0 --add-host USER@HOST"
fi

# ----------------------------------------------------------------- setup ---
[ -f "$ENV_DIR/webui.env" ] || die "The web UI is not installed. Run: sudo ./install-webui.sh"
PORT=$(grep -oP '^PORT=\K[0-9]+' "$ENV_DIR/webui.env" || echo 3000)
OLLAMA_URL=$(grep -oP '^OLLAMA_BASE_URL=\K.*' "$ENV_DIR/webui.env" || echo http://127.0.0.1:11434)

info "Downloading $MODEL (tool-capable model for LAN Assistant)..."
OLLAMA_HOST="${OLLAMA_URL#http://}" ollama pull "$MODEL"

info "Rebuilding the web UI with an SSH client..."
bash "$SCRIPT_DIR/install-webui.sh" --port "$PORT" --ollama-url "$OLLAMA_URL" --no-firewall \
    | grep -E '✔|ERROR|LAN SSH' || true
curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 || die "The web UI did not come back up."

info "Registering the tool and the 'LAN Assistant' model (private to the admin)..."
EMAIL="${WEBUI_ADMIN_EMAIL:-}"; PASSWORD="${WEBUI_ADMIN_PASSWORD:-}"
[ -n "$EMAIL" ] || read -r -p "Open WebUI admin email: " EMAIL
[ -n "$PASSWORD" ] || { read -r -s -p "Password: " PASSWORD; echo; }
WEBUI_ADMIN_EMAIL="$EMAIL" WEBUI_ADMIN_PASSWORD="$PASSWORD" python3 "$SCRIPT_DIR/tools/register_ssh_tool.py" \
    --url "http://127.0.0.1:$PORT" --model "$MODEL" --tool-file "$SCRIPT_DIR/tools/lan_ssh.py"
touch "$MARKER"

cat <<EOF

${C_GRN}LAN SSH tool ready.${C_OFF}
  In the web chat, pick the model "LAN Assistant" and ask e.g.
  "How much disk space is free on nas?" or "Why is nginx failing on web01?"

  Read-only commands run directly; changes wait for your approval.
  Only your admin account can see and use it.

  Add machines:  sudo $0 --add-host USER@HOST [--alias NAME]
  List/remove:   sudo $0 --list  |  --remove-host HOST
EOF
