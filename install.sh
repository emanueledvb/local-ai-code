#!/usr/bin/env bash
#
# install.sh - Install Ollama + a Qwen coding model on Ubuntu, for local /
# offline AI-assisted coding on this machine or on machines in the same LAN.
#
#   sudo ./install.sh                     # auto-pick a model, localhost only
#   sudo ./install.sh --lan               # also serve other machines on the LAN
#   sudo ./install.sh --bundle x.tar      # fully offline install from a bundle
#
# Run ./install.sh --help for all options.

set -euo pipefail

# ---------------------------------------------------------------- defaults ---
CHAT_MODEL=""                                   # empty = auto-select
AUTOCOMPLETE_MODEL="qwen2.5-coder:1.5b-base"    # "none" to skip
PORT=11434
LAN=0
ALLOW_CIDR=""                                   # empty = auto-detect subnet
CONTEXT_LENGTH=16384
KEEP_ALIVE="30m"
BUNDLE=""
OLLAMA_VERSION="${OLLAMA_VERSION:-}"            # empty = latest
UPGRADE=0
WEBUI=0
WEBUI_PORT=3000
CONFIGURE_FIREWALL=1
DRY_RUN=0

OLLAMA_HOME=/usr/share/ollama
MODELS_DIR="$OLLAMA_HOME/.ollama/models"
OVERRIDE_DIR=/etc/systemd/system/ollama.service.d
OVERRIDE_FILE="$OVERRIDE_DIR/10-local-ai-code.conf"

# ----------------------------------------------------------------- helpers ---
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

Model selection
  --model TAG            Chat/edit model (default: auto-selected from RAM/VRAM)
  --autocomplete TAG     Tab-autocomplete model (default: $AUTOCOMPLETE_MODEL)
                         Use 'none' to skip.
  --context N            Default context window in tokens (default: $CONTEXT_LENGTH)
  --keep-alive DUR       How long models stay loaded in memory (default: $KEEP_ALIVE)

Network
  --lan                  Listen on all interfaces so other machines can connect
  --allow CIDR           With --lan and ufw active: only allow this subnet
                         (default: the subnet of the default-route interface)
  --port N               API port (default: $PORT)
  --no-firewall          Do not touch ufw rules

Web interface
  --webui                Also install Open WebUI, a ChatGPT-style chat in the
                         browser for everyone on the LAN (uses Docker)
  --webui-port N         Web UI port (default: $WEBUI_PORT)

Installation
  --bundle FILE          Install fully offline from a bundle made by
                         make-offline-bundle.sh (no internet needed)
  --version X.Y.Z        Install a specific Ollama version (online mode)
  --upgrade              Reinstall/upgrade Ollama even if already installed
  --dry-run              Print what would be done without changing anything
  -h, --help             Show this help

Examples
  sudo $0 --lan
  sudo $0 --model qwen3-coder:30b --lan --allow 10.0.0.0/24
  sudo $0 --bundle local-ai-bundle-amd64.tar --lan
EOF
}

# ---------------------------------------------------------------- arg parse ---
ORIG_ARGS=("$@")
while [ $# -gt 0 ]; do
    case "$1" in
        --model)          CHAT_MODEL="${2:?}"; shift 2 ;;
        --autocomplete)   AUTOCOMPLETE_MODEL="${2:?}"; shift 2 ;;
        --context)        CONTEXT_LENGTH="${2:?}"; shift 2 ;;
        --keep-alive)     KEEP_ALIVE="${2:?}"; shift 2 ;;
        --lan)            LAN=1; shift ;;
        --allow)          ALLOW_CIDR="${2:?}"; shift 2 ;;
        --port)           PORT="${2:?}"; shift 2 ;;
        --no-firewall)    CONFIGURE_FIREWALL=0; shift ;;
        --bundle)         BUNDLE="${2:?}"; shift 2 ;;
        --version)        OLLAMA_VERSION="${2:?}"; shift 2 ;;
        --upgrade)        UPGRADE=1; shift ;;
        --webui)          WEBUI=1; shift ;;
        --webui-port)     WEBUI_PORT="${2:?}"; shift 2 ;;
        --dry-run)        DRY_RUN=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *)                usage >&2; die "Unknown option: $1" ;;
    esac
done

[[ "$PORT" =~ ^[0-9]+$ ]] || die "--port must be a number"
[[ "$CONTEXT_LENGTH" =~ ^[0-9]+$ ]] || die "--context must be a number"

# ------------------------------------------------------------ preflight ------
if [ "$DRY_RUN" = 0 ] && [ "$(id -u)" -ne 0 ]; then
    have sudo || die "Please run as root."
    info "Re-running with sudo..."
    exec sudo -E bash "$0" "${ORIG_ARGS[@]}"
fi

if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [ "${ID:-}" != "ubuntu" ] && [[ "${ID_LIKE:-}" != *ubuntu* ]] && [[ "${ID_LIKE:-}" != *debian* ]]; then
        warn "This script targets Ubuntu; detected '${PRETTY_NAME:-unknown}'. Continuing anyway."
    fi
fi

case "$(uname -m)" in
    x86_64)        ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) die "Unsupported CPU architecture: $(uname -m)" ;;
esac

have systemctl || die "systemd is required (systemctl not found)."

# The user who invoked sudo (to add to the 'ollama' group).
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"

# ------------------------------------------------------- hardware detection ---
RAM_GB=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
VRAM_GB=0
GPU_DESC="none detected"
if have nvidia-smi && nvidia-smi >/dev/null 2>&1; then
    VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null \
              | awk '{s+=$1} END {print s+0}')
    VRAM_GB=$(( VRAM_MB / 1024 ))
    GPU_DESC="NVIDIA: $(nvidia-smi --query-gpu=name --format=csv,noheader | paste -sd, -) (${VRAM_GB} GB VRAM)"
elif have rocm-smi; then
    VRAM_B=$(rocm-smi --showmeminfo vram --csv 2>/dev/null \
             | awk -F, 'NR>1 && $2 ~ /^[0-9]+$/ {s+=$2} END {print s+0}')
    VRAM_GB=$(( VRAM_B / 1024 / 1024 / 1024 ))
    GPU_DESC="AMD ROCm (${VRAM_GB} GB VRAM)"
elif have lspci && lspci | grep -qiE 'vga|3d controller' && lspci | grep -qi nvidia; then
    GPU_DESC="NVIDIA GPU present but driver not loaded (install it for GPU speed: sudo ubuntu-drivers install)"
fi
DISK_FREE_GB=$(df -BG --output=avail "$(dirname "$OLLAMA_HOME")" | tail -1 | tr -dc '0-9')
CPU_CORES=$(nproc)
CPU_AVX2=no
grep -m1 '^flags' /proc/cpuinfo | grep -qw avx2 && CPU_AVX2=yes
VIRT=$(systemd-detect-virt 2>/dev/null || true)

# Pick the best Qwen coder model the hardware can run comfortably.
#   qwen3-coder:30b  ~19 GB  (MoE, 3B active params -> usable even on CPU)
#   qwen2.5-coder:14b ~9 GB
#   qwen2.5-coder:7b  ~5 GB
#   qwen2.5-coder:3b  ~2 GB
#   qwen2.5-coder:1.5b ~1 GB
select_model() {
    if [ "$VRAM_GB" -ge 22 ]; then echo "qwen3-coder:30b"
    elif [ "$VRAM_GB" -ge 11 ]; then echo "qwen2.5-coder:14b"
    elif [ "$VRAM_GB" -ge 6 ]; then echo "qwen2.5-coder:7b"
    elif [ "$RAM_GB" -ge 30 ]; then echo "qwen3-coder:30b"
    elif [ "$RAM_GB" -ge 14 ]; then echo "qwen2.5-coder:7b"
    elif [ "$RAM_GB" -ge 7 ]; then echo "qwen2.5-coder:3b"
    else echo "qwen2.5-coder:1.5b"
    fi
}

# In bundle mode the models come from the bundle; read its metadata.
BUNDLE_DIR=""
# shellcheck disable=SC2317
cleanup() { if [ -n "$BUNDLE_DIR" ] && [ -d "$BUNDLE_DIR" ]; then rm -rf "$BUNDLE_DIR"; fi; }
trap cleanup EXIT

if [ -n "$BUNDLE" ]; then
    [ -f "$BUNDLE" ] || die "Bundle not found: $BUNDLE"
    BUNDLE_DIR=$(mktemp -d /var/tmp/local-ai-bundle.XXXXXX)
    info "Extracting bundle $BUNDLE ..."
    tar -xf "$BUNDLE" -C "$BUNDLE_DIR"
    # The bundle has a single top-level directory.
    BUNDLE_ROOT=$(find "$BUNDLE_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)
    [ -f "$BUNDLE_ROOT/bundle.env" ] || die "Invalid bundle: bundle.env missing."
    # shellcheck disable=SC1091
    . "$BUNDLE_ROOT/bundle.env"
    [ "${BUNDLE_ARCH:-}" = "$ARCH" ] || die "Bundle is for '${BUNDLE_ARCH:-?}', this machine is '$ARCH'."
    [ -n "$CHAT_MODEL" ] || CHAT_MODEL="$BUNDLE_CHAT_MODEL"
    AUTOCOMPLETE_MODEL="${BUNDLE_AUTOCOMPLETE_MODEL:-none}"
    case " $BUNDLE_MODELS " in
        *" $CHAT_MODEL "*) ;;
        *) die "Model '$CHAT_MODEL' is not in the bundle (contains: $BUNDLE_MODELS)" ;;
    esac
fi

[ -n "$CHAT_MODEL" ] || CHAT_MODEL=$(select_model)
[ "$AUTOCOMPLETE_MODEL" = "none" ] && AUTOCOMPLETE_MODEL=""

BIND_ADDR=127.0.0.1
[ "$LAN" = 1 ] && BIND_ADDR=0.0.0.0

echo
info "System summary"
echo "   OS           : ${PRETTY_NAME:-unknown} ($ARCH)"
echo "   RAM          : ${RAM_GB} GB"
echo "   GPU          : $GPU_DESC"
echo "   CPU          : $CPU_CORES cores, AVX2: $CPU_AVX2${VIRT:+ (virtualized: $VIRT)}"
echo "   Free disk    : ${DISK_FREE_GB} GB"
echo "   Chat model   : $CHAT_MODEL"
echo "   Autocomplete : ${AUTOCOMPLETE_MODEL:-<none>}"
echo "   Listen on    : $BIND_ADDR:$PORT"
echo "   Source       : ${BUNDLE:-internet (ollama.com)}"
echo

if [ "$CPU_AVX2" = no ] && [ "$VRAM_GB" -lt 6 ]; then
    warn "This CPU exposes no AVX2: models will run several times slower than they could."
    if [ "$VIRT" = kvm ] || [ "$VIRT" = qemu ]; then
        warn "In Proxmox: VM > Hardware > Processors > Type = 'host' (or x86-64-v3), then power off/on the VM."
    fi
fi
if [ "$VRAM_GB" -lt 6 ] && [ "$CPU_CORES" -lt 6 ]; then
    warn "Only $CPU_CORES CPU cores and no usable GPU: expect a few tokens/second. More cores help."
fi
if [ "${DISK_FREE_GB:-0}" -lt 25 ] && [ "$CHAT_MODEL" = "qwen3-coder:30b" ]; then
    warn "Less than 25 GB free disk; $CHAT_MODEL needs ~19 GB."
fi

# ---------------------------------------------------------- install ollama ---
ollama_installed() { have ollama && [ -f /etc/systemd/system/ollama.service ]; }

create_service() {
    # Mirrors what the official installer does, for offline installs.
    if ! id ollama >/dev/null 2>&1; then
        run useradd -r -s /bin/false -U -m -d "$OLLAMA_HOME" ollama
    fi
    for g in render video; do
        getent group "$g" >/dev/null 2>&1 && run usermod -a -G "$g" ollama
    done
    if [ "$DRY_RUN" = 0 ]; then
        cat > /etc/systemd/system/ollama.service <<EOF
[Unit]
Description=Ollama Service
After=network-online.target

[Service]
ExecStart=/usr/local/bin/ollama serve
User=ollama
Group=ollama
Restart=always
RestartSec=3
Environment="PATH=$PATH"

[Install]
WantedBy=default.target
EOF
    fi
}

install_ollama_online() {
    have curl || run apt-get update -qq
    have curl || run apt-get install -y -qq curl
    # Newer Ollama releases ship as .tar.zst
    have zstd || run apt-get install -y -qq zstd
    info "Installing Ollama ${OLLAMA_VERSION:-(latest)} via the official installer..."
    if [ "$DRY_RUN" = 1 ]; then
        echo "   [dry-run] curl -fsSL https://ollama.com/install.sh | sh"
    else
        curl -fsSL https://ollama.com/install.sh | OLLAMA_VERSION="$OLLAMA_VERSION" sh
    fi
}

install_ollama_offline() {
    local tarball="$BUNDLE_ROOT/ollama-linux-$ARCH.tgz"
    [ -f "$tarball" ] || die "Bundle is missing $tarball"
    info "Installing Ollama ${BUNDLE_OLLAMA_VERSION:-} from bundle..."
    run rm -rf /usr/local/lib/ollama
    run tar -xzf "$tarball" -C /usr/local
    run chmod 755 /usr/local/bin/ollama
    create_service
}

if ollama_installed && [ "$UPGRADE" = 0 ]; then
    ok "Ollama already installed ($(ollama --version 2>/dev/null | tail -1)). Use --upgrade to reinstall."
else
    if [ -n "$BUNDLE" ]; then install_ollama_offline; else install_ollama_online; fi
fi

if [ "$REAL_USER" != "root" ] && id "$REAL_USER" >/dev/null 2>&1; then
    run usermod -a -G ollama "$REAL_USER" || true
fi

# ------------------------------------------------------- configure service ---
info "Configuring Ollama service ($OVERRIDE_FILE)"
run mkdir -p "$OVERRIDE_DIR"
if [ "$DRY_RUN" = 0 ]; then
    cat > "$OVERRIDE_FILE" <<EOF
# Managed by local-ai-code/install.sh
[Service]
Environment="OLLAMA_HOST=$BIND_ADDR:$PORT"
Environment="OLLAMA_MODELS=$MODELS_DIR"
Environment="OLLAMA_CONTEXT_LENGTH=$CONTEXT_LENGTH"
Environment="OLLAMA_KEEP_ALIVE=$KEEP_ALIVE"
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_MAX_LOADED_MODELS=2"
EOF
fi

run systemctl daemon-reload
run systemctl enable ollama >/dev/null 2>&1
run systemctl restart ollama

API="http://127.0.0.1:$PORT"
if [ "$DRY_RUN" = 0 ]; then
    info "Waiting for the Ollama API on $API ..."
    for _ in $(seq 1 60); do
        curl -fsS "$API/api/version" >/dev/null 2>&1 && break
        sleep 1
    done
    curl -fsS "$API/api/version" >/dev/null 2>&1 \
        || die "Ollama did not start. Check: journalctl -u ollama -n 50"
    ok "Ollama is running ($(curl -fsS "$API/api/version"))"
fi

# ------------------------------------------------------------------ models ---
export OLLAMA_HOST="127.0.0.1:$PORT"

if [ -n "$BUNDLE" ]; then
    info "Importing models from bundle into $MODELS_DIR ..."
    run mkdir -p "$MODELS_DIR"
    run cp -a "$BUNDLE_ROOT/models/." "$MODELS_DIR/"
    run chown -R ollama:ollama "$OLLAMA_HOME/.ollama"
    run systemctl restart ollama
    if [ "$DRY_RUN" = 0 ]; then
        for _ in $(seq 1 30); do curl -fsS "$API/api/version" >/dev/null 2>&1 && break; sleep 1; done
    fi
else
    for m in "$CHAT_MODEL" $AUTOCOMPLETE_MODEL; do
        info "Downloading model $m (this can take a while)..."
        run ollama pull "$m"
    done
fi

if [ "$DRY_RUN" = 0 ]; then
    for m in "$CHAT_MODEL" $AUTOCOMPLETE_MODEL; do
        ollama show "$m" >/dev/null 2>&1 || die "Model $m is not available after install."
    done
    ok "Models installed:"
    ollama list | sed 's/^/   /'
fi

# ---------------------------------------------------------------- firewall ---
LAN_IP=""
if [ "$LAN" = 1 ]; then
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
        run ufw allow from "$ALLOW_CIDR" to any port "$PORT" proto tcp comment 'ollama (local-ai-code)'
    elif [ "$CONFIGURE_FIREWALL" = 1 ]; then
        warn "ufw is not active: port $PORT is reachable by ANY host that can reach this machine."
        warn "Ollama has no authentication. Consider: sudo ufw allow ssh && sudo ufw enable && re-run with --lan"
    fi
fi

# -------------------------------------------------------------- smoke test ---
if [ "$DRY_RUN" = 0 ]; then
    info "Running a quick test prompt against $CHAT_MODEL (first load may take a minute)..."
    REPLY=$(curl -fsS --max-time 600 "$API/api/generate" \
        -d "{\"model\":\"$CHAT_MODEL\",\"prompt\":\"Reply with just the word OK.\",\"stream\":false,\"options\":{\"num_predict\":8}}" \
        | sed -nE 's/.*"response":"((\\.|[^"\\])*)".*/\1/p' || true)
    if [ -n "$REPLY" ]; then ok "Model replied: $REPLY"; else warn "Test prompt failed; see: journalctl -u ollama -n 50"; fi
fi

# ----------------------------------------------------------------- summary ---
HOST_FOR_CLIENTS="${LAN_IP:-localhost}"
cat <<EOF

${C_GRN}Done!${C_OFF} Ollama + Qwen are installed and work without internet from now on.

  Ollama API       : http://$HOST_FOR_CLIENTS:$PORT
  OpenAI-compatible: http://$HOST_FOR_CLIENTS:$PORT/v1   (api key: any string)
  Chat model       : $CHAT_MODEL
  Autocomplete     : ${AUTOCOMPLETE_MODEL:-<none>}

Try it in the terminal:
  ollama run $CHAT_MODEL

Set up VS Code (Continue extension) on this or any LAN machine:
  ./client-setup.sh --server $HOST_FOR_CLIENTS:$PORT

Useful commands:
  systemctl status ollama        journalctl -u ollama -f        ollama ps
EOF

# ------------------------------------------------------------------- web UI ---
if [ "$WEBUI" = 1 ]; then
    echo
    info "Installing the web interface (Open WebUI)..."
    WEBUI_ARGS=(--port "$WEBUI_PORT" --ollama-url "http://127.0.0.1:$PORT")
    [ "$CONFIGURE_FIREWALL" = 0 ] && WEBUI_ARGS+=(--no-firewall)
    [ -n "$ALLOW_CIDR" ] && WEBUI_ARGS+=(--allow "$ALLOW_CIDR")
    [ "$DRY_RUN" = 1 ] && WEBUI_ARGS+=(--dry-run)
    if [ -n "$BUNDLE" ] && [ -f "$BUNDLE_ROOT/open-webui-image.tar.gz" ]; then
        WEBUI_ARGS+=(--image-tar "$BUNDLE_ROOT/open-webui-image.tar.gz")
    fi
    bash "$(dirname "$(realpath "$0")")/install-webui.sh" "${WEBUI_ARGS[@]}"
fi

if [ "$LAN" = 0 ] && [ "$WEBUI" = 1 ]; then
    echo "
The Ollama API is private to this machine; the network uses the web UI."
elif [ "$LAN" = 0 ]; then
    echo "
Only this machine can connect. Re-run with --lan (API) or --webui (browser chat)."
fi
exit 0
