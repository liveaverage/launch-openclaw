# OpenClaw Brev Launchable

This repository provides a Brev-oriented bootstrap flow for bringing up OpenClaw on a fresh Ubuntu or Debian-based NVIDIA Brev environment.

The launchable is split into two stages:

- [`launch.sh`](./launch.sh) performs host bootstrap, installs OpenClaw and code-server, and starts the gateway when configuration already exists.
- [`configure.sh`](./configure.sh) runs once from an auto-opened code-server terminal in a local clone of this repo, prompts for an NVIDIA API key, performs non-interactive OpenClaw onboarding, and then hands control back to `launch.sh`.

## What It Does

`launch.sh`:

1. Ensures Node.js 22 or newer is installed.
2. Installs OpenClaw with the official installer while skipping installer onboarding.
3. Verifies the `openclaw` CLI is available.
4. Clones or refreshes `https://github.com/liveaverage/launch-openclaw.git` into `~/launch-openclaw` by default.
5. Installs `code-server`, the custom NV Theme, and the `fabiospampinato.vscode-terminals` extension.
6. Configures code-server to open the cloned repo by default, load its `README.md` on startup, and auto-open `configure.sh` from that local clone on first launch.
7. If OpenClaw is already configured, sources `~/.openclaw/.env`, starts `openclaw gateway`, runs a 20-minute device auto-approval loop, and prints connection details.

`configure.sh`:

1. Prompts for an NVIDIA API key.
2. Runs `openclaw onboard --non-interactive --accept-risk`.
3. Configures the initial model route against NVIDIA’s OpenAI-compatible endpoint:
   - Base URL: `https://integrate.api.nvidia.com/v1`
   - Model: `nvidia/nemotron-3-super-120b-a12b`
4. Stores the key in `~/.openclaw/.env` using the env-ref flow supported by OpenClaw.
5. Re-runs `launch.sh` so the gateway starts immediately after onboarding completes.

## Brev Behavior

On hosts named like `brev-<env_id>`, the launchable derives:

```text
OpenClaw:   https://openclaw0-<env_id>.brevlab.com/chat?session=main
code-server: https://code-server0-<env_id>.brevlab.com
```

If the hostname does not match the Brev naming pattern, it falls back to:

```text
OpenClaw:   http://localhost:3000/chat?session=main
code-server: http://localhost:13337
```

## Re-run Safety

The bootstrap is designed to be safe to run multiple times:

- It skips Node installation when a compatible version is already installed.
- It skips OpenClaw installation when the CLI already exists.
- It refreshes the local `~/launch-openclaw` checkout if it already exists.
- It skips the first-run configure terminal after both `~/.openclaw/.env` and `~/.openclaw/openclaw.json` exist.
- It reuses a running gateway if a previously started process is still alive.
- It keeps state under `~/.local/state/openclaw-bootstrap/`.

## Usage

Run the launchable directly:

```bash
chmod +x launch.sh configure.sh
./launch.sh
```

Run it as your normal user, not as root. The scripts use `sudo` only for package installation and `code-server` service management.

## Output

On the first run, `launch.sh` prints a pending-configuration message with the code-server URL. After `configure.sh` completes, the launch flow prints a block like:

```text
OpenClaw Gateway Started
========================

URL:
https://openclaw0-<env_id>.brevlab.com/chat?session=main

API Token:
<token>

Hostname:
brev-<env_id>

Origin:
https://openclaw0-<env_id>.brevlab.com

code-server:
https://code-server0-<env_id>.brevlab.com
```

## Logs and State

Bootstrap logs are written to:

- `~/.local/state/openclaw-bootstrap/gateway.log`
- `~/.local/state/openclaw-bootstrap/auto-approve.log`

Gateway PID state is tracked in:

- `~/.local/state/openclaw-bootstrap/gateway.pid`

Saved first-run credentials are stored in:

- `~/.openclaw/.env`

## Security Note

OpenClaw agents can execute shell commands, read files, and install software. This launchable is meant for fast bootstrap on development infrastructure, not as a hardened production deployment. Production deployments should isolate agent runtimes, restrict tool permissions, and add approval controls around destructive actions.
