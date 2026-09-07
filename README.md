# auto_agent

One-command, inventory-first deployment for a local AI control plane.

Run the same command on the NVIDIA Ubuntu PC first, then on the Ubuntu laptop:

```bash
curl -fsSL https://raw.githubusercontent.com/caotiensinh/auto_agent/main/install.sh | bash
```

## Core rule

The installer no longer reinstalls components blindly. Every run follows:

```text
Inventory
  ↓
Compare current state
  ↓
Reuse healthy components
  ↓
Install only missing components
  ↓
Apply only required configuration
  ↓
Verify
```

## GPU server preflight

Before package/component changes, the server prints:

- Ubuntu, kernel and hostname
- NVIDIA hardware presence
- every NVIDIA GPU model
- NVIDIA driver version
- VRAM and PCI bus ID
- installed NVIDIA driver package evidence
- Ollama presence/version
- all currently installed Ollama models
- model tool capabilities and context window

If NVIDIA hardware and the driver are already healthy, they are reused and not changed.

If the NVIDIA driver is missing/broken, automatic installation is limited by default to allowed branches:

```text
580 595
```

After a new driver is installed, the installer stops and requires a reboot before continuing.

## Ollama and model reuse

- Existing Ollama is reused by default.
- Ollama is updated only when `UPDATE_OLLAMA=1` is explicitly set.
- Existing models are inventoried before model download.
- If an installed model supports tools and at least the configured agent context, the installer reuses it.
- If no installed model satisfies the policy, only the fallback model is downloaded.

Default fallback:

```text
qwen3.5:9b
```

Force a model:

```bash
curl -fsSL https://raw.githubusercontent.com/caotiensinh/auto_agent/main/install.sh | MODEL=qwen3.5:27b bash
```

## Laptop reuse

Before modifying the laptop, the installer reports whether Hermes, OpenClaw and local Ollama already exist.

- Existing Hermes → reuse; only reconcile remote model endpoint config.
- Missing Hermes → install Hermes only.
- Existing OpenClaw → reuse; only reconcile provider/policy config.
- Missing OpenClaw → install OpenClaw only.
- Existing local Ollama on the laptop is preserved and not replaced.

Optional intentional upgrades:

```text
UPDATE_OLLAMA=1
UPDATE_HERMES=1
UPDATE_OPENCLAW=1
ROTATE_TOKEN=1
```

## Resilient GPU-server discovery

The laptop no longer depends on mDNS alone. Discovery order is:

1. explicit server IP override
2. cached previously-working server
3. `_local-ai._tcp` mDNS
4. `/auto-agent/discovery` scan on the local IPv4 subnet
5. legacy v0.1 `:11434` HTTP-401 fingerprint scan

The new server exposes a LAN-only non-secret endpoint:

```text
GET /auto-agent/discovery
```

It returns only server metadata such as IP, port, SSH user, model and context. It never exposes the API token.

The API token is retrieved by the laptop through SSH.

## Important hostname fix

The laptop connects to SSH by GPU-server IP, not `<hostname>.local`.

This is intentional because two Ubuntu machines can have the same hostname. For example, if both are named `aiserver`, mDNS hostname resolution can collide even though the GPU server is reachable at a valid address such as `192.168.11.112`.

## Security

- Ollama binds only to `127.0.0.1:11434` on the GPU server.
- Nginx exposes the LAN gateway.
- Inference requests require a generated 256-bit Bearer token.
- Token is not published over mDNS or `/auto-agent/discovery`.
- SSH is the secret-transfer trust channel.
- OpenClaw starts with the `messaging` tool profile.
- OpenClaw heartbeat is disabled initially.

## Current architecture

```text
Ubuntu Laptop
├── OpenClaw Gateway
│   └── Ollama native /api/*
├── Hermes Agent
│   └── OpenAI-compatible /v1/*
└── SSH secure credential retrieval
           │
           ▼
Ubuntu NVIDIA GPU Server
├── Nginx authenticated LAN gateway
├── Ollama on 127.0.0.1:11434
└── NVIDIA GPU(s)
```

## Normal deployment

GPU server:

```bash
curl -fsSL https://raw.githubusercontent.com/caotiensinh/auto_agent/main/install.sh | bash
```

Then laptop:

```bash
curl -fsSL https://raw.githubusercontent.com/caotiensinh/auto_agent/main/install.sh | bash
```

If SSH trust does not yet exist, the laptop may request the GPU-server Ubuntu password once for `ssh-copy-id`. Later runs reuse that trust relationship.
