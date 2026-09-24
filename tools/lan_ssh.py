"""
title: LAN SSH
author: local-ai-code
description: Run commands on Linux machines in the LAN over SSH, on demand (user@host). New hosts need the admin to confirm the host-key fingerprint and, once, the user's password to install the assistant's key. Read-only commands run directly; anything that may change a machine needs approval in the chat.
version: 2.0.0
"""

# Installed and kept up to date by install-ssh-tool.sh. Server-side files in
# /etc/local-ai-code/ssh, mounted into the web UI container at /ssh:
#   id_ed25519(.pub)     the assistant's key                    (read-only)
#   state/known_hosts    pinned host keys, strict checking      (read-write)
#   state/hosts          remembered hosts, "user@host[:port] [alias ...]"
#
# Auth flow for a host that is not remembered yet (admin only):
#   1. the target must resolve to a LAN address (valve allowed_networks)
#   2. unknown host key -> Confirm dialog with its SHA256 fingerprint (TOFU);
#      only an explicit Confirm pins it, all connections use strict checking
#   3. key login refused -> masked one-time password dialog; the password is
#      handed to "sshpass -e ssh-copy-id" via the environment, never stored,
#      logged, or returned to the model
#   4. success -> the host is remembered for next time

import asyncio
import ipaddress
import os
import re
import shlex
import shutil
import socket
import tempfile

from pydantic import BaseModel, Field

SSH_DIR = "/ssh"
STATE_DIR = os.path.join(SSH_DIR, "state")
KEY = os.path.join(SSH_DIR, "id_ed25519")
HOSTS_FILE = os.path.join(STATE_DIR, "hosts")
KNOWN_HOSTS = os.path.join(STATE_DIR, "known_hosts")

DEFAULT_NETWORKS = "10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10,127.0.0.0/8,fc00::/7,fe80::/10,::1/128"

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




# ------------------------------------------------------------------ hosts ---

# user@host[:port]. Strict so nothing can be smuggled in as an ssh option
# (e.g. "-oProxyCommand=..."): user and host must start with a letter/digit.
TARGET_RE = re.compile(
    r"^(?:(?P<user>[A-Za-z_][A-Za-z0-9_.-]{0,31})@)?"
    r"(?P<host>[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?)"
    r"(?::(?P<port>[0-9]{1,5}))?$"
)


def parse_target(text: str) -> dict | None:
    """Parse "user@host[:port]" (user optional). Returns None if invalid."""
    m = TARGET_RE.match((text or "").strip())
    if not m:
        return None
    port = int(m["port"]) if m["port"] else 22
    if not 1 <= port <= 65535:
        return None
    return {"user": m["user"], "host": m["host"].lower(), "port": port}


def target_str(t: dict) -> str:
    return f"{t['user']}@{t['host']}" + (f":{t['port']}" if t["port"] != 22 else "")


def known_hosts_name(t: dict) -> str:
    return t["host"] if t["port"] == 22 else f"[{t['host']}]:{t['port']}"


def load_hosts() -> list[dict]:
    hosts = []
    try:
        with open(HOSTS_FILE) as f:
            for line in f:
                line = line.split("#", 1)[0].strip()
                if not line:
                    continue
                first, *aliases = line.split()
                t = parse_target(first)
                if t and t["user"]:
                    hosts.append({**t, "aliases": [a.lower() for a in aliases], "remembered": True})
    except FileNotFoundError:
        pass
    return hosts


def save_hosts(hosts: list[dict]) -> None:
    os.makedirs(STATE_DIR, exist_ok=True)
    tmp = HOSTS_FILE + ".tmp"
    with open(tmp, "w") as f:
        f.write("# Remembered by the LAN SSH tool: user@host[:port] [alias ...]\n")
        for h in hosts:
            f.write(" ".join([target_str(h), *h["aliases"]]) + "\n")
    os.replace(tmp, HOSTS_FILE)


def remember(t: dict, alias: str = "") -> dict:
    """Add/refresh a host in the hosts file; returns the stored entry."""
    hosts = load_hosts()
    alias = alias.strip().lower()
    entry = next((h for h in hosts if h["user"] == t["user"] and h["host"] == t["host"] and h["port"] == t["port"]), None)
    if entry is None:
        entry = {**t, "aliases": [], "remembered": True}
        hosts.append(entry)
    if alias:
        for h in hosts:  # an alias names exactly one host
            if alias in h["aliases"]:
                h["aliases"].remove(alias)
        entry["aliases"].append(alias)
    save_hosts(hosts)
    return entry


def resolve(name: str) -> tuple[dict | None, str]:
    """Map what the admin typed to a target. Returns (target, error)."""
    text = (name or "").strip()
    hosts = load_hosts()
    low = text.lower()
    # 1. remembered alias / host / user@host
    for h in hosts:
        if low in h["aliases"] or low == target_str(h).lower():
            return h, ""
    t = parse_target(text)
    if t is None:
        return None, f"'{text}' is not a valid target. Use user@host or user@ip, e.g. alice@192.168.25.40."
    if not t["user"]:
        matches = [h for h in hosts if h["host"] == t["host"] and h["port"] == t["port"]]
        if len(matches) == 1:
            return matches[0], ""
        if len(matches) > 1:
            return None, f"Several users are remembered for {t['host']}: " + \
                ", ".join(target_str(h) for h in matches) + ". Say which one (user@host)."
        return None, f"Which user should I log in as on {t['host']}? Use user@{t['host']}."
    # 2. user@host that matches a remembered entry
    for h in hosts:
        if (h["user"], h["host"], h["port"]) == (t["user"], t["host"], t["port"]):
            return h, ""
    # 3. on demand
    return {**t, "aliases": [], "remembered": False}, ""


def resolve_ips(host: str) -> list[str]:
    try:
        return sorted({ai[4][0] for ai in socket.getaddrinfo(host, None)})
    except socket.gaierror:
        return []


def in_networks(ips: list[str], networks: str) -> bool:
    nets = [ipaddress.ip_network(n.strip(), strict=False) for n in networks.split(",") if n.strip()]
    return bool(ips) and all(any(ipaddress.ip_address(ip.split("%")[0]) in n for n in nets) for ip in ips)


def is_approved(answer) -> bool:
    """Only an explicit Confirm (True) counts; errors/timeouts/None never do."""
    return answer is True


def why_not(answer) -> str:
    if isinstance(answer, dict) and answer.get("error"):
        return answer["error"]
    return "the user declined"


# ------------------------------------------------------------------- tool ---

class Tools:
    class Valves(BaseModel):
        timeout_seconds: int = Field(default=60, description="Maximum run time of one command.")
        max_output_chars: int = Field(default=8000, description="Longer output is truncated.")
        require_approval_for_all: bool = Field(
            default=False, description="Ask before every command, including read-only ones."
        )
        allowed_networks: str = Field(
            default=DEFAULT_NETWORKS,
            description="Hosts that are not remembered yet must resolve to these networks (comma-separated CIDRs).",
        )

    def __init__(self):
        self.valves = self.Valves()

    # -- subprocess helper (tests replace this) --
    async def _exec(self, args: list[str], stdin: bytes | None = None, env: dict | None = None,
                    timeout: int | None = None) -> tuple[int, str]:
        try:
            proc = await asyncio.create_subprocess_exec(
                *args,
                stdin=asyncio.subprocess.PIPE if stdin is not None else asyncio.subprocess.DEVNULL,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
                env={**os.environ, **(env or {})},
            )
        except FileNotFoundError:
            return 127, f"{args[0]} is missing in the web UI container. Re-run: sudo ./install-ssh-tool.sh --setup"
        try:
            out, _ = await asyncio.wait_for(proc.communicate(stdin), timeout=timeout or self.valves.timeout_seconds)
        except asyncio.TimeoutError:
            proc.kill()
            return -1, "(timed out)"
        return proc.returncode, out.decode(errors="replace")

    def _ssh_base(self, t: dict) -> list[str]:
        return [
            "ssh", "-i", KEY, "-p", str(t["port"]),
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", f"UserKnownHostsFile={KNOWN_HOSTS}",
            "-o", "ConnectTimeout=10",
            "-o", "LogLevel=ERROR",
        ]

    def _public_key(self) -> str:
        try:
            with open(KEY + ".pub") as f:
                return f.read().strip()
        except OSError:
            return "(public key not found)"

    async def _status(self, emitter, text: str, done: bool = False):
        if emitter:
            await emitter({"type": "status", "data": {"description": text, "done": done}})

    # -- trust: pin the host key after the admin checks the fingerprint --
    async def _ensure_host_key(self, t: dict, event_call) -> str:
        code, _ = await self._exec(["ssh-keygen", "-F", known_hosts_name(t), "-f", KNOWN_HOSTS], timeout=10)
        if code == 0:
            return ""
        code, scan = await self._exec(["ssh-keyscan", "-T", "5", "-p", str(t["port"]), t["host"]], timeout=20)
        lines = [l for l in scan.splitlines() if l and not l.startswith("#")]
        if not lines:
            return f"Could not reach SSH on {t['host']}:{t['port']} (is sshd running and the address right?)."
        _, fps = await self._exec(["ssh-keygen", "-lf", "-"], stdin=("\n".join(lines) + "\n").encode(), timeout=10)
        fingerprints = "\n".join(f"- `{' '.join(x.split()[1:2] + x.split()[-1:])}`" for x in fps.splitlines() if x.strip())
        if event_call is None:
            return "Refused: a new host key must be approved in the chat UI."
        answer = await event_call({
            "type": "confirmation",
            "data": {
                "title": f"Trust new host {t['host']}?",
                "message": f"First connection to **{t['host']}** (port {t['port']}). Its SSH host key:\n\n"
                           f"{fingerprints}\n\nConfirm only if this is the machine you mean "
                           f"(on it: `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`).",
            },
        })
        if not is_approved(answer):
            return f"NOT connected: the host key of {t['host']} was not trusted ({why_not(answer)})."
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(KNOWN_HOSTS, "a") as f:
            f.write("\n".join(lines) + "\n")
        return ""

    # -- auth: key login, else a one-time password to install the key --
    async def _ensure_login(self, t: dict, event_call, emitter) -> str:
        code, out = await self._exec(self._ssh_base(t) + [target_str_ssh(t), "true"], timeout=20)
        if code == 0:
            return ""
        if "Host key verification failed" in out or "IDENTIFICATION HAS CHANGED" in out:
            return (f"Refused: the host key of {t['host']} changed since it was trusted. This can mean the machine was "
                    f"reinstalled or someone is intercepting the connection. If expected, the admin can reset it with "
                    f"`sudo ./install-ssh-tool.sh --remove-host {t['host']}` and try again.")
        if "Permission denied" not in out:
            return f"Could not log in to {target_str(t)}: {out.strip()[-300:]}"
        if event_call is None:
            return "Refused: installing the assistant's key needs the chat UI."
        answer = await event_call({
            "type": "input",
            "data": {
                "title": f"Password for {target_str(t)}",
                "message": f"The assistant's key is not installed for **{t['user']}** on **{t['host']}** yet. "
                           f"Enter this user's password once to install it (`ssh-copy-id`). "
                           f"The password is used once and not stored. Cancel to skip.",
                "placeholder": "password",
                "type": "password",
                "input": {"type": "password"},
            },
        })
        manual = (f"To allow it manually, add this line to ~{t['user']}/.ssh/authorized_keys on {t['host']}:\n"
                  f"{self._public_key()}")
        if not isinstance(answer, str) or not answer:
            return f"NOT connected: no password given for {target_str(t)} ({why_not(answer)}).\n{manual}"
        await self._status(emitter, f"{t['host']}: installing the assistant's key")
        # ssh-copy-id needs a writable ~/.ssh for temp files: use a private,
        # throw-away HOME. The password goes via the environment (sshpass -e),
        # never on a command line.
        home = tempfile.mkdtemp(prefix="lan-ssh-")
        try:
            os.makedirs(os.path.join(home, ".ssh"), mode=0o700)
            code, out = await self._exec(
                ["sshpass", "-e", "ssh-copy-id", "-i", KEY + ".pub", "-p", str(t["port"]),
                 "-o", "StrictHostKeyChecking=yes", "-o", f"UserKnownHostsFile={KNOWN_HOSTS}",
                 "-o", "ConnectTimeout=10", target_str_ssh(t)],
                env={"SSHPASS": answer, "HOME": home}, timeout=60,
            )
        finally:
            answer = None  # drop the password
            shutil.rmtree(home, ignore_errors=True)
        if code != 0:
            hint = "wrong password" if code == 5 else out.strip()[-300:]
            return f"NOT connected: could not install the key on {target_str(t)} ({hint}).\n{manual}"
        code, out = await self._exec(self._ssh_base(t) + [target_str_ssh(t), "true"], timeout=20)
        if code != 0:
            return f"The key was installed but key login to {target_str(t)} still fails: {out.strip()[-300:]}"
        return ""

    # ------------------------------------------------------------ tools ---
    async def list_hosts(self, __user__: dict = None) -> str:
        """
        List remembered LAN machines and explain how to reach a new one.
        Any Linux machine in the LAN can be used on demand as user@host or user@ip.
        """
        if (__user__ or {}).get("role") != "admin":
            return "Refused: only the administrator can use the LAN SSH tool."
        hosts = load_hosts()
        lines = []
        for h in hosts:
            alias = f" (alias: {', '.join(h['aliases'])})" if h["aliases"] else ""
            lines.append(f"- {target_str(h)}{alias}")
        remembered = "Remembered hosts:\n" + "\n".join(lines) if lines else "No hosts remembered yet."
        return (f"{remembered}\n\nAny other Linux machine in the LAN can be used on demand: pass host as "
                f"user@host or user@ip (e.g. alice@192.168.25.40). The first time, the user confirms the host-key "
                f"fingerprint and, if the assistant's key is not installed there, enters that user's password once "
                f"in a secure dialog (never in the chat). Successful hosts are remembered.")

    async def remember_host(self, target: str, alias: str = "", __user__: dict = None) -> str:
        """
        Give a remembered host a short alias (e.g. "nas") so it can be named that way later.
        :param target: The host as user@host or user@ip (it must have been connected to before).
        :param alias: Short name to use from now on.
        """
        if (__user__ or {}).get("role") != "admin":
            return "Refused: only the administrator can use the LAN SSH tool."
        t, err = resolve(target)
        if t is None:
            return err
        if not t.get("remembered"):
            return f"{target_str(t)} has not been connected to yet. Run a command on it first."
        if alias and not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,62}", alias):
            return "Aliases may contain letters, digits, '.', '_' and '-'."
        entry = remember(t, alias)
        return f"Remembered {target_str(entry)}" + (f" as '{alias.lower()}'." if alias else ".")

    async def run_command(
        self,
        host: str,
        command: str,
        __user__: dict = None,
        __event_emitter__=None,
        __event_call__=None,
    ) -> str:
        """
        Run a shell command on a LAN machine over SSH and return its real output.
        Use standard Linux commands, e.g. "df -h", "free -h", "uptime", "systemctl status nginx --no-pager",
        "journalctl -u nginx -n 50 --no-pager". Commands that change the machine are shown to the user for
        approval first. A new machine may also ask the user to trust its host key and enter a password once;
        never ask for passwords in the chat yourself.
        :param host: user@host or user@ip (e.g. alice@192.168.25.40), or the alias/short name of a remembered host.
        :param command: The shell command to run on that machine.
        """
        if (__user__ or {}).get("role") != "admin":
            return "Refused: only the administrator can use the LAN SSH tool."

        t, err = resolve(host)
        if t is None:
            return err
        if not t["remembered"]:
            ips = resolve_ips(t["host"])
            if not ips:
                return f"Could not resolve {t['host']}."
            if not in_networks(ips, self.valves.allowed_networks):
                return (f"Refused: {t['host']} ({', '.join(ips)}) is not in the allowed LAN networks "
                        f"({self.valves.allowed_networks}).")

        read_only, reason = classify(command)
        label = f"{t['aliases'][0]} ({t['host']})" if t["aliases"] else t["host"]

        error = await self._ensure_host_key(t, __event_call__)
        if error:
            return error
        error = await self._ensure_login(t, __event_call__, __event_emitter__)
        if error:
            return error
        if not t["remembered"]:
            remember(t)

        if self.valves.require_approval_for_all or not read_only:
            if __event_call__ is None:
                return "Refused: this command needs approval, which is only possible in the chat UI."
            answer = await __event_call__({
                "type": "confirmation",
                "data": {
                    "title": f"Run on {label}?",
                    "message": f"`{command}`\n\nAs user **{t['user']}**. Needs approval because {reason}.",
                },
            })
            if not is_approved(answer):
                return f"NOT run: `{command}` on {t['host']} was not approved ({why_not(answer)})."

        await self._status(__event_emitter__, f"{t['host']}: {command}")
        code, text = await self._exec(self._ssh_base(t) + [target_str_ssh(t), command])
        if len(text) > self.valves.max_output_chars:
            text = text[: self.valves.max_output_chars] + "\n... (output truncated)"
        await self._status(__event_emitter__, f"{t['host']}: {command} (exit {code})", done=True)
        note = "" if t["remembered"] else f"\n(Connected to {target_str(t)} for the first time; it is now remembered.)"
        return f"$ {command}   [{target_str(t)}, exit code {code}]\n{text}{note}"


def target_str_ssh(t: dict) -> str:
    """user@host for the ssh command line (port goes in -p)."""
    return f"{t['user']}@{t['host']}"
