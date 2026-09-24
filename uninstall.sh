#!/usr/bin/env bash
#
# uninstall.sh - Remove what install.sh set up.
#
#   sudo ./uninstall.sh            # remove Ollama, keep downloaded models
#   sudo ./uninstall.sh --purge    # also delete models and the 'ollama' user

set -euo pipefail

PURGE=0
case "${1:-}" in
    --purge) PURGE=1 ;;
    "") ;;
    -h|--help) sed -n '3,6p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
esac

[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"

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
    userdel ollama 2>/dev/null || true
    groupdel ollama 2>/dev/null || true
    rm -rf /usr/share/ollama
else
    echo "Models kept in /usr/share/ollama/.ollama/models (use --purge to delete)."
fi
echo "Done."
