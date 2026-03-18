# OpenClaw Brev Launchable

This launchable provides a Brev-oriented bootstrap flow for bringing up OpenClaw on a fresh Ubuntu or Debian-based NVIDIA Brev environment. By default, the launchable deploys to a low-cost CPU instance to optimize costs for long-running agents. OpenClaw is configured to call remote model endpoints, so no local GPU is required.

## Launchable Quickstart

### Prerequisites

To deploy this launchable, you will need:

- An [NVIDIA Brev](https://brev.nvidia.com) account
- An [NVIDIA Build API key](https://build.nvidia.com/)

To generate an API key, visit [build.nvidia.com/settings/api-keys](https://build.nvidia.com/settings/api-keys). Click the "Generate API Key" button. In the dialog, enter any key name (e.g., "brev-openclaw") and click "Generate Key". Copy the key and store it in a secure location. See [Troubleshoot](#troubleshoot) if you run into issues.

### Deploy

1. **Click the Launchable link** to open the one-click deployment page:

   **[Deploy OpenClaw on Brev](https://brev.nvidia.com/launchable/deploy/now?launchableID=env-3B2Oju9FqUDqcZtHZckFQTS9MJh)**

2. **Review the Instance Configuration.** The Launchable comes pre-configured with the recommended CPU instance and environment settings. Adjust if needed.

3. **Click Deploy.** Brev will provision a cloud instance, install OpenClaw and code-server, and prepare the environment automatically.

4. **Navigate to the Environment Page.** Click the "Go to instance page" button, which replaces the "Deploy Launchable" button after deployment starts.

### Configure

1. Wait until the environment shows the setup script has completed (you will see a "Completed" status pill near the top of the page).
1. Click the "Code Server" button to finish the setup. This opens the code server in a new tab.
1. A terminal will automatically open at the bottom of the page. The script `./configure.sh` from the cloned `launch-openclaw` repo should run automatically.
1. You will be prompted to add your NVIDIA API key here. Paste it ONCE and press the Enter key. **Note**: You cannot see the pasted API key. Pasting it twice will result in an invalid key.
1. The script will finish and show:

   ```
   OpenClaw Gateway Started
   ========================

   URL:
   https://openclaw0-xxxxxxxx.brevlab.com/#token=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

   API Token:
   xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

   Hostname:
   brev-xxxxxxxx

   Origin:
   https://openclaw0-xxxxxxxx.brevlab.com
   ```

1. Copy the full URL (looks like `https://openclaw0-xxxxxxxx.brevlab.com/#token=xxx...`) and open it in a new tab.
1. Click the "Connect" button to open the OpenClaw chat interface. You may need to click this button more than once.
1. Start chatting with the agent.

### Troubleshoot

**build.nvidia.com API key issues**

1. You may need to verify your account before creating an API key.
2. If you see "You do not have permissions to create API Keys in this Organization. Switch Orgs or contact your admin.", click "Switch Org" and follow the instructions to generate a key.

**Error: 403 status code (no body)**
If chatting with the agent results in a 403 error, check the API keys set in `.openclaw/.env`. Confirm they are correct. If you modify those keys, run `./configure.sh` again to update OpenClaw, and copy the link to reopen the OpenClaw UI.

## How It Works

The launchable is split into two stages:

- [`launch.sh`](./launch.sh) performs host bootstrap, installs OpenClaw and code-server, and starts the gateway when configuration already exists.
- [`configure.sh`](./configure.sh) runs once from an auto-opened code-server terminal in a local clone of this repo, prompts for an NVIDIA API key, performs non-interactive OpenClaw onboarding, and then hands control back to `launch.sh`.

### What It Does

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

### Brev Behavior

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

### Re-run Safety

The bootstrap is designed to be safe to run multiple times:

- It skips Node installation when a compatible version is already installed.
- It skips OpenClaw installation when the CLI already exists.
- It refreshes the local `~/launch-openclaw` checkout if it already exists.
- It skips the first-run configure terminal after both `~/.openclaw/.env` and `~/.openclaw/openclaw.json` exist.
- It reuses a running gateway if a previously started process is still alive.
- It keeps state under `~/.local/state/openclaw-bootstrap/`.

### Usage

Run the launchable directly:

```bash
chmod +x launch.sh configure.sh
./launch.sh
```

Run it as your normal user, not as root. The scripts use `sudo` only for package installation and `code-server` service management.

### Output

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

### Logs and State

Bootstrap logs are written to:

- `~/.local/state/openclaw-bootstrap/gateway.log`
- `~/.local/state/openclaw-bootstrap/auto-approve.log`

Gateway PID state is tracked in:

- `~/.local/state/openclaw-bootstrap/gateway.pid`

Saved first-run credentials are stored in:

- `~/.openclaw/.env`

### Security Note

OpenClaw agents can execute shell commands, read files, and install software. This launchable is meant for fast bootstrap on development infrastructure, not as a hardened production deployment. Production deployments should isolate agent runtimes, restrict tool permissions, and add approval controls around destructive actions.
