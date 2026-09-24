#!/usr/bin/env python3
"""Register the LAN SSH tool and the private "LAN Assistant" model in Open WebUI.

Called by install-ssh-tool.sh. Uses the admin API; both items are private
(no access grants), so only the admin account can see and use them.

Environment: WEBUI_ADMIN_EMAIL, WEBUI_ADMIN_PASSWORD
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

TOOL_ID = "lan_ssh"
MODEL_ID = "lan-assistant"

SYSTEM_PROMPT = """You are a Linux system administration assistant with SSH access to machines in the user's LAN.

- Run commands with the run_command tool. The host can be any LAN machine given as user@host or user@ip (e.g. alice@192.168.25.40), or the short name/alias of a remembered host. list_hosts shows the remembered hosts.
- If the user names a machine without a user and it is not remembered, ask which user to log in as.
- The first time a machine is used, the tool itself asks the user to confirm the host-key fingerprint and, if needed, for that user's password in a secure dialog. NEVER ask the user to type a password in the chat, and never repeat or store one.
- When the user wants a short name for a machine ("call it nas"), use remember_host.
- Prefer read-only commands to investigate (df -h, free -h, uptime, systemctl status X --no-pager, journalctl -u X -n 50 --no-pager, ps aux --sort=-%mem | head, docker ps).
- Use sudo only when root is really needed (not for /tmp or the login user's own files); it only works where that user has passwordless sudo.
- Commands that change a machine are shown to the user for approval before they run. Only propose them when the user asks for a change, and explain what they do.
- If a tool result says something was NOT run or NOT connected, tell the user; never pretend it ran.
- Never invent command output: run the command and base your answer on the real result.
- Always add --no-pager to systemctl and journalctl, and avoid interactive commands (top, htop, less, vim): use "top -bn1 | head -20" instead.
- Answer concisely and show the key numbers or lines from the output."""


def api(url, path, token=None, data=None):
    req = urllib.request.Request(url + path, method="POST" if data is not None else "GET")
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    body = json.dumps(data).encode() if data is not None else None
    try:
        with urllib.request.urlopen(req, body, timeout=60) as r:
            return json.loads(r.read() or b"null")
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"{path}: HTTP {e.code} {e.read().decode(errors='replace')[:300]}") from None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--model", required=True, help="Ollama model with tool calling, e.g. qwen3:8b")
    ap.add_argument("--tool-file", required=True)
    args = ap.parse_args()

    try:
        auth = api(args.url, "/api/v1/auths/signin",
                   data={"email": os.environ["WEBUI_ADMIN_EMAIL"], "password": os.environ["WEBUI_ADMIN_PASSWORD"]})
    except RuntimeError:
        sys.exit("Sign-in failed: check the admin email and password.")
    if auth.get("role") != "admin":
        sys.exit("That account is not an admin.")
    token = auth["token"]

    # ---- tool ----
    with open(args.tool_file) as f:
        content = f.read()
    tool = {
        "id": TOOL_ID,
        "name": "LAN SSH",
        "content": content,
        "meta": {"description": "Run commands on LAN machines over SSH on demand (user@host); new hosts and writes need approval."},
        "access_grants": [],
    }
    try:
        api(args.url, f"/api/v1/tools/id/{TOOL_ID}", token)
        api(args.url, f"/api/v1/tools/id/{TOOL_ID}/update", token, tool)
        print("Updated tool 'LAN SSH' (private to admin)")
    except RuntimeError:
        api(args.url, "/api/v1/tools/create", token, tool)
        print("Created tool 'LAN SSH' (private to admin)")

    # ---- model ----
    available = [m["id"] for m in api(args.url, "/api/models", token)["data"]]
    if args.model not in available:
        sys.exit(f"Model {args.model} is not available in Open WebUI (have: {', '.join(available)}).")
    model = {
        "id": MODEL_ID,
        "base_model_id": args.model,
        "name": "LAN Assistant",
        "meta": {
            "description": f"{args.model} with SSH access to your LAN machines (admin only).",
            "toolIds": [TOOL_ID],
            "capabilities": {"builtin_tools": False},
        },
        "params": {
            "system": SYSTEM_PROMPT,
            "function_calling": "native",
            "think": False,
            "temperature": 0.2,
        },
        "access_grants": [],
        "is_active": True,
    }
    try:
        api(args.url, f"/api/v1/models/model?id={MODEL_ID}", token)
        api(args.url, "/api/v1/models/model/update", token, model)
        print(f"Updated model 'LAN Assistant' ({args.model}, private to admin)")
    except RuntimeError:
        api(args.url, "/api/v1/models/create", token, model)
        print(f"Created model 'LAN Assistant' ({args.model}, private to admin)")


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as e:
        sys.exit(f"Open WebUI API error: {e}")
