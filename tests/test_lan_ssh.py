"""Unit tests for tools/lan_ssh.py (run: python3 -m unittest discover -s tests -v).

SSH itself is faked: FakeNet stands in for ssh/ssh-keyscan/ssh-keygen/sshpass,
so these tests cover the tool's decisions (who may connect, which dialogs are
shown, what counts as approval, what gets pinned/remembered).
"""

import asyncio
import importlib.util
import os
import sys
import tempfile
import types
import unittest

try:
    import pydantic  # noqa: F401
except ImportError:  # the tool only needs BaseModel/Field for its valves
    stub = types.ModuleType("pydantic")

    class BaseModel:
        def __init__(self, **kw):
            for k, v in type(self).__dict__.items():
                if not k.startswith("_") and not callable(v):
                    setattr(self, k, kw.get(k, v))

    stub.BaseModel = BaseModel
    stub.Field = lambda default=None, **kw: default
    sys.modules["pydantic"] = stub

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("lan_ssh", os.path.join(HERE, "..", "tools", "lan_ssh.py"))
lan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lan)

ADMIN = {"role": "admin"}
USER = {"role": "user"}
PASSWORD = "s3cret-one-time"


class FakeNet:
    """Pretends to be the LAN: which users have the key, which password is right."""

    def __init__(self):
        self.authorized = set()          # (user, host) with the assistant's key installed
        self.passwords = {}              # (user, host) -> password
        self.calls = []                  # every command the tool tried to run

    async def exec(self, args, stdin=None, env=None, timeout=None):
        self.calls.append({"args": list(args), "env": dict(env or {}), "stdin": stdin})
        prog = args[0]
        if prog == "ssh-keygen" and args[1] == "-F":
            name = args[2]
            try:
                with open(lan.KNOWN_HOSTS) as f:
                    return (0, "") if any(l.split(" ", 1)[0] == name for l in f) else (1, "")
            except FileNotFoundError:
                return 1, ""
        if prog == "ssh-keyscan":
            host = args[-1]
            return 0, f"{host} ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEKEY{host}\n"
        if prog == "ssh-keygen" and args[1] == "-lf":
            return 0, "256 SHA256:FAKEfingerprint123 host (ED25519)\n"
        if prog == "sshpass":
            user, host = args[-1].split("@")
            if env.get("SSHPASS") == self.passwords.get((user, host)):
                self.authorized.add((user, host))
                return 0, "Number of key(s) added: 1"
            return 5, ""
        if prog == "ssh":
            target, command = args[-2], args[-1]
            user, host = target.split("@")
            if (user, host) not in self.authorized:
                return 255, f"{target}: Permission denied (publickey,password)."
            return 0, "" if command == "true" else f"<output of {command}>"
        raise AssertionError(f"unexpected command {args}")

    def ran(self, command):
        return any(c["args"][0] == "ssh" and c["args"][-1] == command for c in self.calls)


class Dialogs:
    """Scripted answers for __event_call__, recording what was shown."""

    def __init__(self, *answers):
        self.answers = list(answers)
        self.shown = []

    async def __call__(self, event):
        self.shown.append(event)
        return self.answers.pop(0) if self.answers else None

    def kinds(self):
        return [e["type"] for e in self.shown]


class Base(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        d = self.tmp.name
        lan.STATE_DIR = os.path.join(d, "state")
        lan.KEY = os.path.join(d, "id_ed25519")
        lan.HOSTS_FILE = os.path.join(lan.STATE_DIR, "hosts")
        lan.KNOWN_HOSTS = os.path.join(lan.STATE_DIR, "known_hosts")
        with open(lan.KEY + ".pub", "w") as f:
            f.write("ssh-ed25519 AAAAPUBLIC local-ai-code@server\n")
        self.net = FakeNet()
        self.tool = lan.Tools()
        self.tool._exec = self.net.exec
        self._orig_ips = lan.resolve_ips
        lan.resolve_ips = lambda host: ["8.8.8.8"] if host == "public.example" else ["192.168.25.40"]

    def tearDown(self):
        lan.resolve_ips = self._orig_ips
        self.tmp.cleanup()

    def pin(self, host):
        os.makedirs(lan.STATE_DIR, exist_ok=True)
        with open(lan.KNOWN_HOSTS, "a") as f:
            f.write(f"{host} ssh-ed25519 AAAAPINNED\n")

    async def ssh(self, host, command, dialogs=None, user=ADMIN):
        return await self.tool.run_command(host, command, __user__=user, __event_call__=dialogs)


class TestParsing(Base):
    def test_user_at_ip(self):
        self.assertEqual(lan.parse_target("alice@192.168.25.40"), {"user": "alice", "host": "192.168.25.40", "port": 22})

    def test_user_at_host_port(self):
        self.assertEqual(lan.parse_target("Bob@NAS.lan:2222"), {"user": "Bob", "host": "nas.lan", "port": 2222})

    def test_bare_host(self):
        self.assertEqual(lan.parse_target("nas"), {"user": None, "host": "nas", "port": 22})

    def test_rejects_option_injection_and_junk(self):
        for bad in ["-oProxyCommand=sh", "alice@-oProxyCommand=x", "alice@", "@host", "alice@host;rm -rf /",
                    "alice@host name", "alice@host:0", "alice@host:99999", "a b@host", "alice@$(id)", ""]:
            self.assertIsNone(lan.parse_target(bad), bad)

    def test_aliases_and_short_names(self):
        lan.remember(lan.parse_target("alice@192.168.25.40"), "nas")
        lan.remember(lan.parse_target("bob@10.0.0.5:2222"))
        self.assertEqual(lan.resolve("nas")[0]["user"], "alice")
        self.assertEqual(lan.resolve("NAS")[0]["host"], "192.168.25.40")
        self.assertEqual(lan.resolve("192.168.25.40")[0]["user"], "alice")        # short name
        self.assertEqual(lan.resolve("bob@10.0.0.5:2222")[0]["port"], 2222)
        self.assertTrue(lan.resolve("alice@192.168.25.40")[0]["remembered"])

    def test_on_demand_and_errors(self):
        t, err = lan.resolve("carol@192.168.25.41")
        self.assertFalse(t["remembered"])
        self.assertIsNone(lan.resolve("192.168.25.99")[0])
        self.assertIn("Which user", lan.resolve("192.168.25.99")[1])
        lan.remember(lan.parse_target("alice@192.168.25.40"))
        lan.remember(lan.parse_target("bob@192.168.25.40"))
        self.assertIn("Several users", lan.resolve("192.168.25.40")[1])

    def test_alias_moves_between_hosts(self):
        lan.remember(lan.parse_target("alice@192.168.25.40"), "box")
        lan.remember(lan.parse_target("bob@192.168.25.41"), "box")
        self.assertEqual(lan.resolve("box")[0]["user"], "bob")
        self.assertEqual(sum("box" in h["aliases"] for h in lan.load_hosts()), 1)

    def test_networks(self):
        self.assertTrue(lan.in_networks(["192.168.25.40"], lan.DEFAULT_NETWORKS))
        self.assertTrue(lan.in_networks(["127.0.0.2"], lan.DEFAULT_NETWORKS))
        self.assertFalse(lan.in_networks(["8.8.8.8"], lan.DEFAULT_NETWORKS))
        self.assertFalse(lan.in_networks(["192.168.1.1", "8.8.8.8"], lan.DEFAULT_NETWORKS))
        self.assertFalse(lan.in_networks([], lan.DEFAULT_NETWORKS))


class TestAdminOnly(Base):
    async def test_non_admin_refused_everywhere_without_side_effects(self):
        d = Dialogs(True, True)
        for coro in [self.ssh("alice@192.168.25.40", "df -h", d, user=USER),
                     self.ssh("alice@192.168.25.40", "df -h", d, user=None),
                     self.tool.list_hosts(__user__=USER),
                     self.tool.remember_host("alice@192.168.25.40", "nas", __user__=USER)]:
            self.assertIn("only the administrator", await coro)
        self.assertEqual(self.net.calls, [])
        self.assertEqual(d.shown, [])
        self.assertFalse(os.path.exists(lan.HOSTS_FILE))


class TestOnDemand(Base):
    async def test_new_host_with_key_already_installed(self):
        """Not in the hosts file, key works: host-key confirm, run, remember."""
        self.net.authorized.add(("alice", "192.168.25.40"))
        d = Dialogs(True)
        out = await self.ssh("alice@192.168.25.40", "df -h", d)
        self.assertIn("<output of df -h>", out)
        self.assertEqual(d.kinds(), ["confirmation"])
        self.assertIn("SHA256:FAKEfingerprint123", d.shown[0]["data"]["message"])
        self.assertTrue(lan.resolve("alice@192.168.25.40")[0]["remembered"])
        # next time: by short name, no dialogs at all
        d2 = Dialogs()
        out = await self.ssh("192.168.25.40", "uptime", d2)
        self.assertIn("<output of uptime>", out)
        self.assertEqual(d2.shown, [])

    async def test_host_key_not_trusted(self):
        self.net.authorized.add(("alice", "192.168.25.40"))
        for answer in [False, None, {"error": "Event call timed out."}, "yes", 1]:
            with self.subTest(answer=answer):
                out = await self.ssh("alice@192.168.25.40", "df -h", Dialogs(answer))
                self.assertIn("NOT connected", out)
                self.assertFalse(self.net.ran("df -h"))
                self.assertFalse(os.path.exists(lan.KNOWN_HOSTS))
                self.assertFalse(lan.load_hosts())

    async def test_new_host_needs_ui(self):
        out = await self.ssh("alice@192.168.25.40", "df -h", None)
        self.assertIn("must be approved in the chat UI", out)
        self.assertFalse(self.net.ran("df -h"))

    async def test_password_installs_key_once(self):
        self.net.passwords[("alice", "192.168.25.40")] = PASSWORD
        d = Dialogs(True, PASSWORD)
        out = await self.ssh("alice@192.168.25.40", "df -h", d)
        self.assertIn("<output of df -h>", out)
        self.assertEqual(d.kinds(), ["confirmation", "input"])
        self.assertEqual(d.shown[1]["data"]["input"]["type"], "password")
        sshpass = [c for c in self.net.calls if c["args"][0] == "sshpass"]
        self.assertEqual(len(sshpass), 1)
        self.assertEqual(sshpass[0]["env"]["SSHPASS"], PASSWORD)
        self.assertFalse(os.path.exists(sshpass[0]["env"]["HOME"]))      # temp HOME cleaned up
        # the password never appears on a command line or in what the model sees
        self.assertFalse(any(PASSWORD in " ".join(c["args"]) for c in self.net.calls))
        self.assertNotIn(PASSWORD, out)
        with open(lan.HOSTS_FILE) as f:
            self.assertNotIn(PASSWORD, f.read())
        # key is installed now: next run asks nothing
        d2 = Dialogs()
        await self.ssh("alice@192.168.25.40", "uptime", d2)
        self.assertEqual(d2.shown, [])

    async def test_password_cancel_timeout_wrong(self):
        self.net.passwords[("alice", "192.168.25.40")] = PASSWORD
        self.pin("192.168.25.40")
        for answer in [None, False, "", {"error": "Client session disconnected."}]:
            with self.subTest(answer=answer):
                out = await self.ssh("alice@192.168.25.40", "df -h", Dialogs(answer))
                self.assertIn("NOT connected", out)
                self.assertIn("ssh-ed25519 AAAAPUBLIC", out)      # manual instructions
                self.assertFalse(any(c["args"][0] == "sshpass" for c in self.net.calls))
        out = await self.ssh("alice@192.168.25.40", "df -h", Dialogs("wrong"))
        self.assertIn("wrong password", out)
        self.assertNotIn("wrong", out.split("(")[0])
        self.assertFalse(self.net.ran("df -h"))
        self.assertFalse(lan.load_hosts())

    async def test_public_address_refused(self):
        out = await self.ssh("alice@public.example", "df -h", Dialogs(True, True))
        self.assertIn("not in the allowed LAN networks", out)
        self.assertEqual(self.net.calls, [])

    async def test_changed_host_key_is_not_auto_fixed(self):
        self.pin("192.168.25.40")
        async def exec_(args, **kw):
            self.net.calls.append({"args": args})
            if args[0] == "ssh-keygen":
                return 0, ""
            return 255, "@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@\nHost key verification failed."
        self.tool._exec = exec_
        d = Dialogs(True, PASSWORD)
        out = await self.ssh("alice@192.168.25.40", "df -h", d)
        self.assertIn("host key of 192.168.25.40 changed", out)
        self.assertEqual(d.shown, [])


class TestApproval(Base):
    def setUp(self):
        super().setUp()
        lan.remember(lan.parse_target("alice@192.168.25.40"), "nas")
        self.pin("192.168.25.40")
        self.net.authorized.add(("alice", "192.168.25.40"))

    async def test_read_only_runs_without_dialog(self):
        d = Dialogs()
        self.assertIn("<output of free -h>", await self.ssh("nas", "free -h", d))
        self.assertEqual(d.shown, [])

    async def test_write_needs_confirm_even_for_remembered_host(self):
        for cmd in ["sudo systemctl restart nginx", "rm -rf /tmp/x", "echo hi > /tmp/x"]:
            d = Dialogs(True)
            out = await self.ssh("nas", cmd, d)
            self.assertEqual(d.kinds(), ["confirmation"], cmd)
            self.assertIn(cmd, d.shown[0]["data"]["message"])
            self.assertIn(f"<output of {cmd}>", out)

    async def test_cancel_timeout_error_are_not_approval(self):
        for answer in [False, None, {"error": "Event call timed out."}, {"error": "Client session disconnected."},
                       "true", 1, [True]]:
            with self.subTest(answer=answer):
                out = await self.ssh("nas", "touch /tmp/x", Dialogs(answer))
                self.assertIn("NOT run", out)
                self.assertFalse(self.net.ran("touch /tmp/x"))

    async def test_write_without_ui_refused(self):
        out = await self.ssh("nas", "touch /tmp/x", None)
        self.assertIn("only possible in the chat UI", out)
        self.assertFalse(self.net.ran("touch /tmp/x"))

    async def test_on_demand_write_asks_host_then_command(self):
        self.net.authorized.add(("carol", "192.168.25.40"))
        d = Dialogs(True)   # host already pinned -> only the write confirm
        out = await self.ssh("carol@192.168.25.40", "touch /tmp/x", d)
        self.assertEqual(d.kinds(), ["confirmation"])
        self.assertIn("Run on", d.shown[0]["data"]["title"])
        self.assertIn("<output of touch /tmp/x>", out)


class TestListAndRemember(Base):
    async def test_list_hosts_explains_on_demand(self):
        out = await self.tool.list_hosts(__user__=ADMIN)
        self.assertIn("No hosts remembered yet", out)
        self.assertIn("user@host", out)
        lan.remember(lan.parse_target("alice@192.168.25.40"), "nas")
        out = await self.tool.list_hosts(__user__=ADMIN)
        self.assertIn("alice@192.168.25.40 (alias: nas)", out)

    async def test_remember_host_alias(self):
        self.assertIn("not been connected", await self.tool.remember_host("alice@192.168.25.40", "nas", __user__=ADMIN))
        lan.remember(lan.parse_target("alice@192.168.25.40"))
        self.assertIn("as 'nas'", await self.tool.remember_host("alice@192.168.25.40", "NAS", __user__=ADMIN))
        self.assertEqual(lan.resolve("nas")[0]["user"], "alice")
        self.assertIn("Aliases may", await self.tool.remember_host("alice@192.168.25.40", "-bad", __user__=ADMIN))


class TestClassifier(unittest.TestCase):
    CASES = {
        "df -h": True, "uptime && free -m": True, "free -h | grep Mem": True,
        "systemctl status nginx --no-pager": True, "journalctl -u nginx -n 50 --no-pager": True,
        "docker ps -a": True, "ip addr": True, "ls -la /etc | head": True, "cat /etc/os-release": True,
        "awk '{print $1}' /etc/passwd": True, "LANG=C df -h": True,
        "git -C /srv/app log --oneline -5": False, "sudo systemctl restart nginx": False,
        "systemctl restart nginx": False, "rm -rf /tmp/x": False, "echo hi > /tmp/x": False,
        "cat $(which ssh)": False, "find /tmp -name '*.log' -delete": False, "sed -i s/a/b/ f": False,
        "docker rm -f x": False, "apt install htop": False, "ip link set eth0 down": False,
        "df -h; reboot": False, "sleep 100 &": False, "awk 'BEGIN{system(\"reboot\")}'": False,
        "crontab -r": False, "reboot": False, "journalctl --vacuum-size=100M": False, "tee /etc/x": False,
    }

    def test_cases(self):
        for command, expected in self.CASES.items():
            with self.subTest(command=command):
                self.assertEqual(lan.classify(command)[0], expected)


if __name__ == "__main__":
    unittest.main()
