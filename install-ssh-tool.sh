#!/usr/bin/env bash
#
# install-ssh-tool.sh - Let the web chat run commands on Linux machines in the
# LAN over SSH ("LAN Assistant" model, admin account only).
#
#   sudo ./install-ssh-tool.sh                  # set up (or upgrade) the tool
#
# Then, in the chat, pick "LAN Assistant" and name any machine as user@host:
#   "SSH to alice@192.168.25.40 and check the disk space"
# The first time, the chat asks you to confirm the host-key fingerprint and,
# if the assistant's key is not installed there yet, for that user's password
# once. Successful hosts are remembered (use a short name or alias next time).
#
# Optional shortcuts from the terminal:
#   sudo ./install-ssh-tool.sh --add-host me@192.168.1.20 --alias nas
#   sudo ./install-ssh-tool.sh --list
#   sudo ./install-ssh-tool.sh --remove-host 192.168.1.20
#
# Read-only commands (df, free, systemctl status, journalctl ...) run directly.
# Anything that may change a machine pops up an approval dialog in the chat.
# Requires install.sh --webui (or install-webui.sh) to have been run first.

set -euo pipefail

# qwen3:8b: the smallest Qwen that calls tools reliably on CPU (the coder
# models don't; qwen3:4b ignores think=false and is far slower). ~5 GB.
MODEL="qwen3:8b"
ADD_HOSTS=()
ALIASES=()
REMOVE_HOSTS=()
LIST=0

SCRIPT_DIR=$(cd "$(dirname "$(realpath "$0")")" && pwd)
ENV_DIR=/etc/local-ai-code
SSH_DIR="$ENV_DIR/ssh"            # mounted read-only at /ssh in the web UI
STATE_DIR="$SSH_DIR/state"        # mounted read-write at /ssh/state
KEY="$SSH_DIR/id_ed25519"
HOSTS="$STATE_DIR/hosts"
KNOWN="$STATE_DIR/known_hosts"
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

With no options: set up or upgrade the tool (key, SSH-capable web UI image,
$MODEL, tool + private "LAN Assistant" model). Hosts are added on demand
from the chat; the options below are optional shortcuts.

  --add-host USER@HOST   Pre-install the assistant's key on HOST for USER
                         (asks to confirm the host key and USER's password)
  --alias NAME           Short name for the preceding --add-host (e.g. nas)
  --remove-host HOST     Forget HOST (all users) and its pinned host key
  --list                 Show remembered hosts and the assistant's public key
  --model TAG            Tool-capable model for "LAN Assistant" (default: $MODEL)
  -h, --help             Show this help
EOF
}

ORIG_ARGS=("$@")
SETUP=1
while [ $# -gt 0 ]; do
    case "$1" in
        --add-host)    ADD_HOSTS+=("${2:?}"); ALIASES+=(""); SETUP=0; shift 2 ;;
        --alias)       [ ${#ADD_HOSTS[@]} -gt 0 ] || die "--alias must follow --add-host"
                       ALIASES[${#ALIASES[@]}-1]="${2:?}"; shift 2 ;;
        --remove-host) REMOVE_HOSTS+=("${2:?}"); SETUP=0; shift 2 ;;
        --list)        LIST=1; SETUP=0; shift ;;
        --model)       MODEL="${2:?}"; shift 2 ;;
        --setup)       shift ;;   # kept for compatibility: setup is the default
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

# ------------------------------------------------------------ key + state ---
install -d -m 700 "$SSH_DIR" "$STATE_DIR"
# Older versions kept hosts/known_hosts next to the key (read-only mount).
for f in hosts known_hosts; do
    if [ -f "$SSH_DIR/$f" ] && [ ! -s "$STATE_DIR/$f" ]; then
        mv "$SSH_DIR/$f" "$STATE_DIR/$f"
        info "Moved $SSH_DIR/$f to $STATE_DIR/"
    fi
done
touch "$HOSTS" "$KNOWN"
chmod 600 "$KNOWN" "$HOSTS"
if [ ! -f "$KEY" ]; then
    info "Creating the assistant's SSH key $KEY"
    ssh-keygen -q -t ed25519 -N "" -C "local-ai-code@$(hostname)" -f "$KEY"
fi

# ----------------------------------------------------------------- hosts ---
host_re() {  # regex matching hosts-file lines for a host (any user, optional :port)
    local h="${1#*@}"; h="${h%%:*}"
    printf '^[^#[:space:]]*@%s(:[0-9]+)?([[:space:]]|$)' "${h//./\\.}"
}

for h in "${REMOVE_HOSTS[@]}"; do
    name="${h#*@}"; name="${name%%:*}"
    re=$(host_re "$h")
    if grep -qE "$re" "$HOSTS"; then
        ports=$(grep -E "$re" "$HOSTS" | awk '{print $1}' | sed -nE 's/.*:([0-9]+)$/\1/p')
        sed -i -E "/$re/d" "$HOSTS"
        ssh-keygen -q -R "$name" -f "$KNOWN" >/dev/null 2>&1 || true
        for p in $ports; do ssh-keygen -q -R "[$name]:$p" -f "$KNOWN" >/dev/null 2>&1 || true; done
        rm -f "$KNOWN.old"
        ok "Forgot $name. Its authorized_keys may still contain the assistant's key: remove the"
        echo "   line ending in 'local-ai-code@$(hostname)' from ~/.ssh/authorized_keys on $name."
    else
        # Not remembered, but a pinned key may exist (e.g. a declined first use).
        if ssh-keygen -F "$name" -f "$KNOWN" >/dev/null 2>&1; then
            ssh-keygen -q -R "$name" -f "$KNOWN" >/dev/null 2>&1
            ok "Removed the pinned host key of $name."
        else
            warn "$name is not remembered."
        fi
        rm -f "$KNOWN.old"
    fi
done

for i in "${!ADD_HOSTS[@]}"; do
    target="${ADD_HOSTS[$i]}"; alias="${ALIASES[$i]}"
    [[ "$target" =~ ^[A-Za-z_][A-Za-z0-9_.-]*@[A-Za-z0-9][A-Za-z0-9.-]*$ ]] \
        || die "Use USER@HOST for --add-host (got '$target')."
    info "Installing the assistant's key on $target."
    echo "   Check the host-key fingerprint if asked, then enter $target's password."
    # StrictHostKeyChecking=ask: an unknown host key is shown here for you to confirm.
    ssh-copy-id -i "$KEY.pub" -o "UserKnownHostsFile=$KNOWN" -o StrictHostKeyChecking=ask \
        -o ConnectTimeout=10 "$target" \
        || die "Could not copy the key to $target. Check the address, user and that sshd runs there."
    ssh -i "$KEY" -o "UserKnownHostsFile=$KNOWN" -o ConnectTimeout=10 -o BatchMode=yes \
        -o StrictHostKeyChecking=yes "$target" true \
        || die "Key login to $target does not work."
    grep -vxE "$target([[:space:]].*)?" "$HOSTS" > "$HOSTS.tmp" || true
    if [ -n "$alias" ]; then   # an alias names exactly one host
        sed -i -E "s/[[:space:]]$alias([[:space:]]|$)/\1/" "$HOSTS.tmp"
    fi
    echo "$target${alias:+ $alias}" >> "$HOSTS.tmp"
    mv "$HOSTS.tmp" "$HOSTS"; chmod 600 "$HOSTS"
    ok "Remembered $target${alias:+ (alias: $alias)}"
done

if [ "$LIST" = 1 ]; then
    echo "Remembered hosts ($HOSTS):"
    grep -vE '^\s*(#|$)' "$HOSTS" | sed 's/^/  /' || echo "  (none yet: they are added when first used from the chat)"
    echo
    echo "Assistant's public key (to allow a host without a password, add it to"
    echo "\$HOME/.ssh/authorized_keys of the user on that host):"
    echo "  $(cat "$KEY.pub")"
fi

[ "$SETUP" = 1 ] || exit 0

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
    "SSH to alice@192.168.25.40 and check the disk space"
  First use of a machine: confirm its host-key fingerprint and, if needed,
  enter that user's password once (in a dialog, never in the chat). The host
  is then remembered: "check uptime on 192.168.25.40" or an alias
  ("call it nas") works next time.

  Read-only commands run directly; changes wait for your approval.
  Only your admin account can see and use it.

  Remembered hosts / public key:  sudo $0 --list
  Forget a host:                  sudo $0 --remove-host HOST
EOF
