#!/usr/bin/env bash
#
# make-offline-bundle.sh - Build a single .tar containing Ollama, Qwen models
# and these scripts, so an air-gapped Ubuntu machine can be set up with:
#
#   sudo ./install.sh --bundle local-ai-bundle-amd64.tar --lan
#
# Run this on any Linux machine WITH internet. No root and no existing Ollama
# install is needed: a temporary Ollama server is started just to pull models.

set -euo pipefail

CHAT_MODEL="qwen2.5-coder:7b"
AUTOCOMPLETE_MODEL="qwen2.5-coder:1.5b-base"
EXTRA_MODELS=""
ARCH=""
OLLAMA_VERSION="${OLLAMA_VERSION:-}"
OUTPUT=""
WITH_VSCODE=0
WITH_WEBUI=0
WEBUI_IMAGE="ghcr.io/open-webui/open-webui:main"

info() { echo "==> $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
    cat <<EOF
Usage: $0 [options]

  --model TAG            Chat model to include (default: $CHAT_MODEL)
  --autocomplete TAG     Autocomplete model (default: $AUTOCOMPLETE_MODEL, 'none' to skip)
  --extra TAG            Additional model to include (repeatable)
  --arch amd64|arm64     Target CPU architecture (default: this machine's)
  --version X.Y.Z        Ollama version (default: latest)
  --with-webui           Also include the Open WebUI browser chat (Docker image, ~2 GB;
                         needs Docker here, and Docker installed on the target)
  --with-vscode          Also include the Continue VS Code extension (.vsix, linux-x64/arm64)
  -o, --output FILE      Output file (default: local-ai-bundle-<arch>.tar)
  -h, --help             Show this help

Model size guide (download / RAM needed, roughly):
  qwen2.5-coder:3b   2 GB   |  qwen2.5-coder:14b  9 GB
  qwen2.5-coder:7b   5 GB   |  qwen3-coder:30b   19 GB
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --model)        CHAT_MODEL="${2:?}"; shift 2 ;;
        --autocomplete) AUTOCOMPLETE_MODEL="${2:?}"; shift 2 ;;
        --extra)        EXTRA_MODELS="$EXTRA_MODELS ${2:?}"; shift 2 ;;
        --arch)         ARCH="${2:?}"; shift 2 ;;
        --version)      OLLAMA_VERSION="${2:?}"; shift 2 ;;
        --with-vscode)  WITH_VSCODE=1; shift ;;
        --with-webui)   WITH_WEBUI=1; shift ;;
        -o|--output)    OUTPUT="${2:?}"; shift 2 ;;
        -h|--help)      usage; exit 0 ;;
        *)              usage >&2; die "Unknown option: $1" ;;
    esac
done

[ "$AUTOCOMPLETE_MODEL" = "none" ] && AUTOCOMPLETE_MODEL=""

case "$(uname -m)" in
    x86_64)        HOST_ARCH=amd64 ;;
    aarch64|arm64) HOST_ARCH=arm64 ;;
    *) die "Unsupported host architecture: $(uname -m)" ;;
esac
ARCH="${ARCH:-$HOST_ARCH}"
case "$ARCH" in amd64|arm64) ;; *) die "--arch must be amd64 or arm64" ;; esac
OUTPUT="${OUTPUT:-local-ai-bundle-$ARCH.tar}"

for t in curl tar gzip; do have "$t" || die "'$t' is required."; done
have zstd || die "'zstd' is required (Ubuntu: sudo apt-get install zstd)."
if [ "$WITH_WEBUI" = 1 ]; then
    if ! { have docker && docker info >/dev/null 2>&1; }; then
        die "--with-webui needs a working Docker (try with sudo)."
    fi
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WORK=$(mktemp -d "${TMPDIR:-/var/tmp}/local-ai-build.XXXXXX")
SERVER_PID=""
# shellcheck disable=SC2317
cleanup() {
    if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
    rm -rf "$WORK"
}
trap cleanup EXIT

ROOT="$WORK/local-ai-bundle"
mkdir -p "$ROOT/models"

VER_PARAM="${OLLAMA_VERSION:+?version=$OLLAMA_VERSION}"

# Download the Ollama release for an arch and write it as a gzip tarball
# (gzip so the target machine does not need zstd).
fetch_ollama() {
    local arch="$1" out="$2" base="https://ollama.com/download/ollama-linux-$1"
    info "Downloading Ollama ${OLLAMA_VERSION:-latest} for linux-$arch ..."
    if curl -fsIL "$base.tar.zst$VER_PARAM" >/dev/null 2>&1; then
        curl -fL --progress-bar "$base.tar.zst$VER_PARAM" | zstd -dc | gzip -1 > "$out"
    else
        curl -fL --progress-bar "$base.tgz$VER_PARAM" -o "$out"
    fi
}

fetch_ollama "$ARCH" "$ROOT/ollama-linux-$ARCH.tgz"

# A host-runnable ollama binary to pull the models with.
RUNTIME="$WORK/runtime"
mkdir -p "$RUNTIME"
if [ "$ARCH" = "$HOST_ARCH" ]; then
    tar -xzf "$ROOT/ollama-linux-$ARCH.tgz" -C "$RUNTIME"
else
    fetch_ollama "$HOST_ARCH" "$WORK/host.tgz"
    tar -xzf "$WORK/host.tgz" -C "$RUNTIME"
fi
OLLAMA_BIN="$RUNTIME/bin/ollama"
[ -x "$OLLAMA_BIN" ] || die "Ollama binary not found in release archive."
BUNDLE_OLLAMA_VERSION=$("$OLLAMA_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | tail -1 || true)

# Temporary private server storing models straight into the bundle.
PORT=$(( 20000 + RANDOM % 20000 ))
export OLLAMA_HOST="127.0.0.1:$PORT"
export OLLAMA_MODELS="$ROOT/models"
info "Starting temporary Ollama server on $OLLAMA_HOST ..."
"$OLLAMA_BIN" serve > "$WORK/serve.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 30); do
    curl -fsS "http://$OLLAMA_HOST/api/version" >/dev/null 2>&1 && break
    sleep 1
done
curl -fsS "http://$OLLAMA_HOST/api/version" >/dev/null 2>&1 \
    || { cat "$WORK/serve.log" >&2; die "Temporary Ollama server did not start."; }

# Normalise whitespace: "a b c"
read -r -a MODEL_LIST <<< "$CHAT_MODEL $AUTOCOMPLETE_MODEL $EXTRA_MODELS"
MODELS="${MODEL_LIST[*]}"
for m in "${MODEL_LIST[@]}"; do
    info "Pulling $m ..."
    "$OLLAMA_BIN" pull "$m"
done
"$OLLAMA_BIN" list

kill "$SERVER_PID"; wait "$SERVER_PID" 2>/dev/null || true; SERVER_PID=""

if [ "$WITH_VSCODE" = 1 ]; then
    case "$ARCH" in amd64) VS_PLAT=linux-x64 ;; arm64) VS_PLAT=linux-arm64 ;; esac
    info "Downloading Continue VS Code extension ($VS_PLAT) from open-vsx.org ..."
    VSIX_URL=$(curl -fsS "https://open-vsx.org/api/Continue/continue/$VS_PLAT/latest" \
               | grep -oE '"download":"[^"]+"' | head -1 | cut -d'"' -f4)
    [ -n "$VSIX_URL" ] || die "Could not find Continue extension download URL."
    curl -fL --progress-bar "$VSIX_URL" -o "$ROOT/continue-$VS_PLAT.vsix"
fi

# Ship the scripts inside the bundle so it is self-contained.
if [ "$WITH_WEBUI" = 1 ]; then
    info "Saving Open WebUI image ($WEBUI_IMAGE, linux/$ARCH) ..."
    docker pull --platform "linux/$ARCH" "$WEBUI_IMAGE"
    docker save "$WEBUI_IMAGE" | gzip -1 > "$ROOT/open-webui-image.tar.gz"
fi

for f in install.sh install-webui.sh webui-defaults.sh install-ssh-tool.sh client-setup.sh uninstall.sh README.md; do
    [ -f "$SCRIPT_DIR/$f" ] && cp "$SCRIPT_DIR/$f" "$ROOT/"
done
cp -r "$SCRIPT_DIR/tools" "$ROOT/"

cat > "$ROOT/bundle.env" <<EOF
BUNDLE_ARCH="$ARCH"
BUNDLE_OLLAMA_VERSION="$BUNDLE_OLLAMA_VERSION"
BUNDLE_CHAT_MODEL="$CHAT_MODEL"
BUNDLE_AUTOCOMPLETE_MODEL="$AUTOCOMPLETE_MODEL"
BUNDLE_MODELS="$MODELS"
BUNDLE_CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EOF

info "Writing $OUTPUT ..."
tar -cf "$OUTPUT" -C "$WORK" local-ai-bundle
( cd "$(dirname "$OUTPUT")" && sha256sum "$(basename "$OUTPUT")" > "$(basename "$OUTPUT").sha256" )

cat <<EOF

Bundle ready: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))
  Ollama $BUNDLE_OLLAMA_VERSION (linux-$ARCH), models: $MODELS

Copy it (plus install.sh) to the offline machine, e.g. on a USB stick, then:
  tar -xf $(basename "$OUTPUT") local-ai-bundle/install.sh --strip-components=1
  sudo ./install.sh --bundle $(basename "$OUTPUT") --lan
EOF
