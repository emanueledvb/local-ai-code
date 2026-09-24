# local-ai-code

These scripts set up a private AI coding assistant that runs **offline** on Ubuntu. It uses
[Ollama](https://ollama.com) and the **Qwen Coder** models. Use it from any browser on your network through a
ChatGPT-style web chat ([Open WebUI](https://openwebui.com)), with nothing to install on the other computers. You
can also connect from VS Code (the Continue extension), aider, the `ollama` CLI or any OpenAI-compatible tool.

Your code never leaves your network.

```
 ┌──────────────── Ubuntu server ────────────────┐         ┌──── any computer / phone ────┐
 │  Open WebUI  (Docker, :3000, user logins)     │◄────────┤  web browser                 │
 │       │ localhost                             │  LAN    └──────────────────────────────┘
 │       ▼                                       │         ┌──── dev laptop / desktop ────┐
 │  ollama.service  (systemd, :11434)            │◄────────┤  VS Code + Continue, aider,  │
 │    ├─ qwen2.5-coder:7b / qwen3-coder:30b      │ (--lan) │  ollama CLI, curl ...        │
 │    └─ qwen2.5-coder:1.5b-base (autocomplete)  │         └──────────────────────────────┘
 └───────────────────────────────────────────────┘
```

## Quick start (server has internet during install)

```bash
git clone https://github.com/emanueledvb/local-ai-code.git
cd local-ai-code
sudo ufw allow OpenSSH && sudo ufw --force enable   # optional: lets the installer limit access to your LAN
sudo ./install.sh --webui        # browser chat at http://<server-ip>:3000
```

Open `http://<server-ip>:3000` in any browser on the network. The first account you create becomes the
administrator (see [Web chat](#web-chat-open-webui)).

To also use VS Code, aider or the API from other machines, add `--lan`, which exposes the Ollama API on port 11434.
Then run this on each machine:

```bash
./client-setup.sh --server 192.168.1.50      # the server's IP, printed by install.sh
```

When the install finishes, everything works with no internet connection.

## Fully offline / air-gapped install

1. On **any Linux machine with internet** (no root and no Ollama needed), run:

   ```bash
   ./make-offline-bundle.sh --model qwen2.5-coder:7b --with-vscode
   # -> local-ai-bundle-amd64.tar (+ .sha256)
   ```

2. Copy the `.tar` to the offline Ubuntu machine, for example on a USB stick.
3. On the offline machine, run:

   ```bash
   tar -xf local-ai-bundle-amd64.tar local-ai-bundle/install.sh local-ai-bundle/install-webui.sh --strip-components=1
   sudo ./install.sh --bundle local-ai-bundle-amd64.tar --lan
   ```

4. On offline client machines, the bundle also contains `client-setup.sh` and, with `--with-vscode`, the Continue
   `.vsix`. Run:

   ```bash
   tar -xf local-ai-bundle-amd64.tar
   cd local-ai-bundle
   ./client-setup.sh --server 192.168.1.50 --vsix continue-linux-x64.vsix
   ```

To include the web chat, build the bundle with `--with-webui` (Docker must work on the build machine) and install
with `--webui`. Docker itself must already be installed on the offline machine, from the Ubuntu `docker.io`
package or your local mirror.

Use `--arch arm64` to build a bundle for ARM servers. Add more models with `--extra TAG` (you can repeat it).

## What `install.sh` does

1. It detects your RAM and GPU (NVIDIA through `nvidia-smi`, AMD through `rocm-smi`) and picks a model:

   | Hardware                         | Chat model          | Download size |
   |----------------------------------|---------------------|---------------|
   | GPU ≥ 22 GB VRAM                 | `qwen3-coder:30b`   | ~19 GB        |
   | GPU ≥ 11 GB                      | `qwen2.5-coder:14b` | ~9 GB         |
   | GPU ≥ 6 GB                       | `qwen2.5-coder:7b`  | ~5 GB         |
   | CPU only, RAM ≥ 30 GB            | `qwen3-coder:30b`   | ~19 GB        |
   | CPU only, RAM ≥ 14 GB            | `qwen2.5-coder:7b`  | ~5 GB         |
   | CPU only, RAM ≥ 7 GB             | `qwen2.5-coder:3b`  | ~2 GB         |
   | smaller                          | `qwen2.5-coder:1.5b`| ~1 GB         |

   `qwen3-coder:30b` is a mixture-of-experts model with only about 3B parameters active per token, so it runs
   usably on a CPU with enough RAM. It also installs `qwen2.5-coder:1.5b-base` for fast tab-autocomplete.
   Override either choice with `--model` or `--autocomplete`.
2. It installs Ollama as a systemd service. Online installs use the official installer. Offline installs use the
   binaries from the bundle.
3. It writes `/etc/systemd/system/ollama.service.d/10-local-ai-code.conf`, which sets the listen address, context
   length (`--context`, default 16384), keep-alive and flash attention.
4. It downloads or imports the models, then runs a test prompt.
5. With `--lan` and `ufw` active, it opens the port **only to your local subnet**. Use `--allow CIDR` to choose a
   different range.
6. With `--webui`, it runs `install-webui.sh` (see below).

Run `./install.sh --help` for all options. Try `--dry-run` to see what would happen without changing anything.

## Web chat (Open WebUI)

`sudo ./install.sh --webui` (or `sudo ./install-webui.sh` on a server that already has Ollama) runs
[Open WebUI](https://openwebui.com) in Docker. It gives you a Claude/ChatGPT-style chat in the browser, with chat
history, markdown and code highlighting, file uploads, and user accounts.

- **Address:** `http://<server-ip>:3000`. Change the port with `--webui-port` or `install-webui.sh --port`.
- **Accounts:** the first account created becomes the admin, and sign-up then closes. Add people in
  **Admin Panel → Users → +**. Or turn on **Admin Panel → Settings → General → Enable New Sign Ups**; new users then
  wait for your approval.
- **Private by design:** the web UI reaches Ollama over `localhost`. Without `--lan`, the Ollama API is not exposed
  at all, and the network only sees the web UI, which requires a login.
- **Offline:** it runs with `OFFLINE_MODE`, telemetry off and no cloud providers. The embedding models it needs for
  document uploads ship inside the image.
- **Tuned for CPU servers:** optional background generations (tags, follow-up suggestions, autocomplete) are off,
  so they don't slow down your answers. Chat titles are still generated. You can re-enable them under
  **Admin Panel → Settings → Interface**.
- **No built-in tools:** Open WebUI offers models tools such as time, memory and `ask_user`. Small Qwen coder
  models can't use them and reply with raw JSON like `{"name": "ask_user", ...}`, so tools are off for every model.
- **Existing install:** Open WebUI saves model defaults in its database on first start, so re-running the
  installer doesn't change them. To set the default model and turn off tools on an install that already has an
  admin, run `./webui-defaults.sh --model qwen2.5-coder:3b`. It asks for your admin login.
- **Data:** users and chats live in the Docker volume `open-webui` and survive upgrades. Settings are in
  `/etc/local-ai-code/webui.env`.

```bash
docker logs -f open-webui               # logs
sudo ./install-webui.sh --upgrade       # update to the latest Open WebUI
```

## Running in a Proxmox VM

Change these VM settings before installing. Power the VM off and on again afterwards; a reboot from inside the
guest is not enough.

| Setting                         | Recommended                        | Why |
|---------------------------------|------------------------------------|-----|
| Processors → Type               | `host` (or `x86-64-v3`)            | The default `x86-64-v2-AES` hides AVX/AVX2, which makes inference several times slower. |
| Processors → Sockets/Cores      | 1 socket, as many cores as you can spare | Token speed on a CPU scales with cores and memory bandwidth. |
| Memory → Ballooning             | Off (or minimum = maximum)         | Proxmox can reclaim memory while a model is loaded. |
| Network → Firewall              | Allow TCP 3000 (web UI) and/or 11434 (API) from your LAN | Only needed if the Proxmox firewall is enabled for the VM. |
| DHCP / IP                       | Give the VM a fixed IP             | Clients store the server address. |

A PCI-passed-through GPU (with machine type `q35`) is by far the biggest speed-up if the host has one.

## Security note

The Ollama API has **no authentication**. With `--lan`, anyone who can reach port 11434 can use the models. If you
only need the browser chat, skip `--lan`: the web UI has logins, and Ollama then stays private to the server. Turn
on `ufw` before running the installer so it can restrict both ports to your subnet:

```bash
sudo ufw allow OpenSSH && sudo ufw --force enable
sudo ./install.sh --webui          # add --lan only if you need VS Code / API access
```

## Using it

| Tool              | How                                                                          |
|-------------------|------------------------------------------------------------------------------|
| Browser           | `http://SERVER:3000` (needs `--webui`)                                       |
| VS Code           | The Continue sidebar (chat, edit) and tab-autocomplete. `client-setup.sh` writes `~/.continue/config.yaml`. |
| Terminal          | `ollama run qwen2.5-coder:7b` (on the server, or anywhere with `OLLAMA_HOST` set) |
| aider             | `./client-setup.sh --aider`, then `aider` in your repo                       |
| OpenAI-compatible | Base URL `http://SERVER:11434/v1`, any API key                               |

To keep VS Code fully offline, also turn off Continue telemetry: Settings → search for "Continue telemetry" →
uncheck it.

## Maintenance

```bash
systemctl status ollama          # service state
journalctl -u ollama -f          # logs
ollama ps                        # loaded models, GPU/CPU split
ollama pull qwen3-coder:30b      # add another model (needs internet)
sudo ./install.sh --upgrade      # upgrade Ollama
sudo ./uninstall.sh              # remove Ollama + web UI, keep models and chats
sudo ./uninstall.sh --purge      # remove everything, including models, users and chats
```

## Troubleshooting

- **Slow responses:** run `ollama ps`. If `PROCESSOR` shows CPU on a machine with an NVIDIA GPU, install the
  driver with `sudo ubuntu-drivers install`, reboot, then run `sudo systemctl restart ollama`.
- **A client can't connect:** check that the server was installed with `--lan`. Then run `sudo ufw status` and
  `curl http://SERVER:11434/api/version` from the client.
- **A reply is raw JSON such as `{"name": "ask_user", ...}`:** the model was offered tools it can't use. Run
  `./webui-defaults.sh`, then start a new chat.
- **The model can't "check the server":** chat models only produce text. They can't run commands or see the
  machine they run on.
- **The web UI doesn't load:** run `docker ps` and `docker logs open-webui`. From another machine, check that
  `sudo ufw status` on the server allows port 3000.
- **Out of memory:** use a smaller model with `sudo ./install.sh --model qwen2.5-coder:3b`, or lower the context
  with `--context 8192`.
