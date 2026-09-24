#!/usr/bin/env bash
#
# uninstall.sh - Remove what install.sh set up.
#
#   sudo ./uninstall.sh            # remove Ollama + web UI, keep models and chats
#   sudo ./uninstall.sh --purge    # also delete models, chats/users and the 'ollama' user

set -euo pipefail

PURGE=0
case "${1:-}" in
    --purge) PURGE=1 ;;
    "") ;;
    -h|--help) sed -n '3,6p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
esac

[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"

if command -v docker >/dev/null 2>&1 && docker container inspect open-webui >/dev/null 2>&1; then
    echo "==> Removing Open WebUI container"
    docker rm -f open-webui >/dev/null
fi

echo "==> Stopping Ollama service"
systemctl disable --now ollama 2>/dev/null || true
rm -f /etc/systemd/system/ollama.service
rm -rf /etc/systemd/system/ollama.service.d
systemctl daemon-reload

echo "==> Removing Ollama binaries"
rm -f /usr/local/bin/ollama
rm -rf /usr/local/lib/ollama

if command -v ufw >/dev/null 2>&1; then
    # Delete rules added by install.sh (highest number first so numbering stays valid).
    ufw status numbered 2>/dev/null | grep 'local-ai-code' | grep -oE '^\[ *[0-9]+\]' | tr -dc '0-9\n' \
        | sort -rn | while read -r n; do yes | ufw delete "$n" >/dev/null && echo "==> Removed ufw rule $n"; done
fi

if [ "$PURGE" = 1 ]; then
    echo "==> Deleting models and the ollama user"
    if pkill -u ollama 2>/dev/null; then sleep 2; fi
    userdel ollama 2>/dev/null || true
    groupdel ollama 2>/dev/null || true
    rm -rf /usr/share/ollama
    if [ -f /etc/local-ai-code/ssh/state/hosts ] && grep -qvE '^\s*(#|$)' /etc/local-ai-code/ssh/state/hosts; then
        echo "==> The LAN SSH key stays authorized on these hosts; remove the line ending in"
        echo "    'local-ai-code@$(hostname)' from ~/.ssh/authorized_keys on each:"
        grep -vE '^\s*(#|$)' /etc/local-ai-code/ssh/state/hosts | sed 's/^/      /'
    fi
    rm -rf /etc/local-ai-code
    if command -v docker >/dev/null 2>&1; then
        echo "==> Deleting Open WebUI data (users, chats) and image"
        docker volume rm open-webui >/dev/null 2>&1 || true
        docker image rm local-ai-code/open-webui-ssh:latest >/dev/null 2>&1 || true
        docker image rm ghcr.io/open-webui/open-webui:main >/dev/null 2>&1 || true
    fi
else
    echo "Models and web UI chats/users kept (use --purge to delete)."
fi
echo "Done."
