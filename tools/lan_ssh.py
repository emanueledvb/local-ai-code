"""
title: LAN SSH
author: local-ai-code
description: Run commands on registered Linux machines in the LAN over SSH. Read-only commands run directly; anything that may change a machine needs the admin's approval in the chat.
version: 1.0.0
"""

# Installed and kept up to date by install-ssh-tool.sh. Configuration lives on
# the server in /etc/local-ai-code/ssh (mounted read-only at /ssh):
#   id_ed25519   private key used for every connection
#   known_hosts  host keys recorded when a host was added (strict checking)
#   hosts        one "user@host [alias ...]" per line

import asyncio
import os
import re
import shlex

from pydantic import BaseModel, Field

SSH_DIR = "/ssh"

# Commands that only read state. Anything else needs approval.
READ_ONLY_COMMANDS = {
    "cat", "head", "tail", "less", "more", "grep", "egrep", "fgrep", "zgrep", "zcat",
    "ls", "ll", "tree", "stat", "file", "du", "df", "wc", "sort", "uniq", "cut", "tr",
    "column", "echo", "printf", "pwd", "whoami", "id", "groups", "hostname", "hostnamectl",
    "uname", "uptime", "date", "timedatectl", "w", "who", "last", "lastlog", "free", "vmstat",
    "iostat", "mpstat", "top", "ps", "pgrep", "pstree", "lsblk", "blkid", "findmnt", "mount",
    "lscpu", "lsmem", "lspci", "lsusb", "lsmod", "dmidecode", "sensors", "nproc", "arch",
    "ip", "ss", "netstat", "ping", "traceroute", "tracepath", "dig", "nslookup", "host",
    "journalctl", "dmesg", "env", "printenv", "which", "whereis", "type", "md5sum",
    "sha1sum", "sha256sum", "diff", "cmp", "readlink", "realpath", "basename", "dirname",
    "lsof", "getent", "locale", "nvidia-smi", "smartctl", "zpool", "zfs", "crontab",
    "systemctl", "docker", "podman", "apt", "apt-cache", "dpkg", "dpkg-query", "snap",
    "git", "find", "sed", "awk", "test", "true", "sleep",
}

# For these, only the listed first arguments are read-only.
READ_ONLY_SUBCOMMANDS = {
    "systemctl": {"status", "is-active", "is-enabled", "is-failed", "list-units",
                  "list-unit-files", "list-timers", "show", "cat", "--failed"},
    "docker": {"ps", "images", "logs", "inspect", "stats", "version", "info", "top", "port",
               "diff", "history"},
    "podman": {"ps", "images", "logs", "inspect", "stats", "version", "info", "top", "port"},
    "apt": {"list", "show", "policy", "search"},
    "apt-cache": {"show", "policy", "search", "depends", "rdepends", "showpkg"},
    "dpkg": {"-l", "-L", "-s", "--list", "--listfiles", "--status", "-S", "--search"},
    "snap": {"list", "info", "services", "version"},
    "git": {"status", "log", "diff", "show", "branch", "remote", "rev-parse", "describe",
            "ls-files", "blame", "tag"},
    "crontab": {"-l"},
    "ip": {"a", "addr", "address", "r", "route", "l", "link", "n", "neigh", "-br", "-s",
           "-4", "-6", "-c"},
    "zpool": {"status", "list", "iostat", "get"},
    "zfs": {"list", "get"},
    "dmesg": {"-T", "-H", "--ctime", "-l", "--level", "-k"},
}

# Argument patterns that turn otherwise read-only commands into writes.
WRITE_ARGS = {
    "find": {"-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprintf", "-fls"},
    "sed": {"-i", "--in-place"},
    "journalctl": {"--vacuum-size", "--vacuum-time", "--vacuum-files", "--rotate", "--flush"},
    "hostnamectl": {"set-hostname", "hostname", "set-icon-name", "set-chassis", "set-location"},
    "timedatectl": {"set-time", "set-timezone", "set-ntp", "set-local-rtc"},
    "ip": {"add", "del", "delete", "set", "flush", "change", "replace"},
    "top": set(),
}

# Shell syntax that can write files, run hidden commands or background jobs.
UNSAFE_SHELL = re.compile(r"(>|`|\$\(|<\(|>\(|(?<![&])&(?![&]))")
SEPARATORS = re.compile(r"\|\||&&|;|\||\n")


def classify(command: str) -> tuple[bool, str]:
    """Return (read_only, reason). Errs on the side of 'needs approval'."""
    if UNSAFE_SHELL.search(command):
        return False, "uses redirection, command substitution or background jobs"
    for segment in SEPARATORS.split(command):
        segment = segment.strip()
        if not segment:
            continue
        try:
            words = shlex.split(segment)
        except ValueError:
            return False, "could not parse the command"
        # Skip leading VAR=value assignments.
        while words and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[0]):
            words = words[1:]
        if not words:
            continue
        cmd = os.path.basename(words[0])
        args = words[1:]
        if cmd not in READ_ONLY_COMMANDS:
            return False, f"'{cmd}' can change the system"
        subs = READ_ONLY_SUBCOMMANDS.get(cmd)
        if subs is not None:
            first = next((a for a in args if a not in ("--no-pager", "--no-stream", "-a", "--all")), None)
            if first is not None and first not in subs:
                return False, f"'{cmd} {first}' can change the system"
        bad = WRITE_ARGS.get(cmd, set())
        if any(a in bad or a.split("=")[0] in bad for a in args):
            return False, f"'{cmd}' with these options can change the system"
        if cmd == "awk" and re.search(r"system\s*\(|print\s*[^;]*>|getline", segment):
            return False, "awk script runs commands or writes files"
    return True, "read-only"


def load_hosts() -> list[dict]:
    hosts = []
    try:
        with open(os.path.join(SSH_DIR, "hosts")) as f:
            for line in f:
                line = line.split("#", 1)[0].strip()
                if not line:
                    continue
                target, *aliases = line.split()
                user, _, addr = target.rpartition("@")
                hosts.append({"target": target, "user": user, "host": addr, "aliases": aliases})
    except FileNotFoundError:
        pass
    return hosts


def resolve(name: str) -> dict | None:
    name = name.strip().lower()
    for h in load_hosts():
        names = {h["target"].lower(), h["host"].lower(), *(a.lower() for a in h["aliases"])}
        if name in names:
            return h
    return None


class Tools:
    class Valves(BaseModel):
        timeout_seconds: int = Field(default=60, description="Maximum run time of one command.")
        max_output_chars: int = Field(default=8000, description="Longer output is truncated.")
        require_approval_for_all: bool = Field(
            default=False, description="Ask before every command, including read-only ones."
        )

    def __init__(self):
        self.valves = self.Valves()

    async def list_hosts(self, __user__: dict = None) -> str:
        """
        List the LAN machines that commands can be run on.
        Call this first when the user does not name a known host.
        """
        if (__user__ or {}).get("role") != "admin":
            return "Refused: only the administrator can use the LAN SSH tool."
        hosts = load_hosts()
        if not hosts:
            return "No hosts are registered. The admin can add one with: sudo ./install-ssh-tool.sh --add-host user@host"
        lines = []
        for h in hosts:
            alias = f" (also called: {', '.join(h['aliases'])})" if h["aliases"] else ""
            lines.append(f"- {h['host']} as user {h['user']}{alias}")
        return "Registered hosts:\n" + "\n".join(lines)

    async def run_command(
        self,
        host: str,
        command: str,
        __user__: dict = None,
        __event_emitter__=None,
        __event_call__=None,
    ) -> str:
        """
        Run a shell command on a registered LAN machine over SSH and return its output.
        Use standard Linux commands, e.g. "df -h", "free -h", "uptime", "systemctl status nginx",
        "journalctl -u nginx -n 50 --no-pager". Commands that change the machine are shown to the
        user for approval first.
        :param host: Hostname, IP address or alias of a registered machine (see list_hosts).
        :param command: The shell command to run on that machine.
        """
        if (__user__ or {}).get("role") != "admin":
            return "Refused: only the administrator can use the LAN SSH tool."

        target = resolve(host)
        if target is None:
            known = ", ".join(h["host"] for h in load_hosts()) or "none"
            return f"Refused: '{host}' is not a registered host. Registered hosts: {known}."

        label = f"{target['aliases'][0]} ({target['host']})" if target["aliases"] else target["host"]
        read_only, reason = classify(command)
        if self.valves.require_approval_for_all or not read_only:
            if __event_call__ is None:
                return "Refused: this command needs approval, which is only possible in the chat UI."
            approved = await __event_call__(
                {
                    "type": "confirmation",
                    "data": {
                        "title": f"Run on {label}?",
                        "message": f"`{command}`\n\nAs user **{target['user']}**. "
                        f"Needs approval because {reason}.",
                    },
                }
            )
            # Only an explicit "Confirm" (True) counts. A closed tab or timeout
            # returns an error dict, which must not be mistaken for approval.
            if approved is not True:
                why = approved.get("error") if isinstance(approved, dict) else "the user declined"
                return f"NOT run: `{command}` on {target['host']} was not approved ({why})."

        if __event_emitter__:
            await __event_emitter__(
                {"type": "status", "data": {"description": f"{target['host']}: {command}", "done": False}}
            )

        ssh = [
            "ssh",
            "-i", os.path.join(SSH_DIR, "id_ed25519"),
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", f"UserKnownHostsFile={os.path.join(SSH_DIR, 'known_hosts')}",
            "-o", "ConnectTimeout=10",
            "-o", "LogLevel=ERROR",
            target["target"],
            command,
        ]
        try:
            proc = await asyncio.create_subprocess_exec(
                *ssh, stdin=asyncio.subprocess.DEVNULL,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
            )
            out, _ = await asyncio.wait_for(proc.communicate(), timeout=self.valves.timeout_seconds)
            code = proc.returncode
        except asyncio.TimeoutError:
            proc.kill()
            out, code = b"(command timed out)", -1
        except FileNotFoundError:
            return "Error: the ssh client is missing in the web UI container. Re-run: sudo ./install-ssh-tool.sh"

        text = out.decode(errors="replace")
        if len(text) > self.valves.max_output_chars:
            text = text[: self.valves.max_output_chars] + "\n... (output truncated)"

        if __event_emitter__:
            await __event_emitter__(
                {"type": "status", "data": {"description": f"{target['host']}: {command} (exit {code})", "done": True}}
            )
        return f"$ {command}   [host {target['host']}, exit code {code}]\n{text}"
