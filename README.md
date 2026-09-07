# auto_agent

One-command, inventory-first deployment for a local AI control plane using Hermes + OpenClaw + a remote Ollama GPU server.

Run the same command on the NVIDIA Ubuntu PC first, then on the Ubuntu laptop:

```bash
curl -fsSL https://raw.githubusercontent.com/caotiensinh/auto_agent/main/install.sh | bash
```

## Core rule

Every run follows:

```text
Inventory → Compare → Reuse healthy components → Install only missing parts → Configure → Verify
```

The installer does not reinstall NVIDIA drivers, Ollama, models, Hermes, OpenClaw, Node, or system packages blindly.

## GPU server

Before changes, the server inventories:

- Ubuntu and kernel
- NVIDIA GPU model(s)
- driver version
- VRAM and PCI bus
- NVIDIA packages
- Ollama version
- installed models
- model context windows and capabilities

Healthy GPU/driver/Ollama components are reused. Existing compatible tool-capable models are reused. A fallback model is downloaded only when no installed model satisfies policy.

Default fallback:

```text
qwen3.5:9b
```

## Laptop

The laptop reuses existing Hermes/OpenClaw/Node installations, discovers the GPU server, retrieves the inference credential through SSH, verifies a real remote inference, then reconciles the two agents.

Boot-persistent services are enabled with systemd user services plus `loginctl linger=yes`:

```text
Hermes Gateway
Hermes Dashboard
OpenClaw Gateway
Auto Agent Control Center
```

## Unified Control Center

After client deployment, users do not need to open two separate URLs manually.

The laptop exposes one authenticated LAN entry point:

```text
http://LAPTOP_IP:8088
```

A PC on the same LAN needs only a web browser. It does not need Hermes, OpenClaw, Node, Python, or Ollama installed.

The Control Center has four main views:

```text
Unified Chat | Hermes | OpenClaw | Status
```

### Unified Chat routing

Explicit routing:

```text
@hermes check this Ubuntu network problem
@openclaw send a notification through the configured channel
```

`@hermes` routes the prompt to Hermes one-shot agent execution.

`@openclaw` routes the prompt to OpenClaw's Gateway Chat Completions endpoint.

`Auto` mode applies a lightweight task router:

- code / shell / SSH / Linux / network / security / diagnostics → Hermes
- messaging / channels / scheduling / notifications / orchestration → OpenClaw

The selected agent is shown in the Unified Chat response.

### Native agent interfaces

The `Hermes` menu embeds the real Hermes Dashboard.

The `OpenClaw` menu embeds the real OpenClaw Control UI.

The user can move between both from the same outer Control Center without typing addresses or credentials again.

## Single login

The first Control Center installation creates local credentials automatically:

```text
username: admin
password: generated random secret
```

Credentials are stored mode `0600` under:

```text
~/.config/auto_agent/control.env
```

They are reused on later installer runs.

Display the login credentials locally on the laptop:

```bash
auto-agent credentials
```

Open the center locally:

```bash
auto-agent center
```

The login session is shared across the laptop IP, so the authenticated Hermes/OpenClaw proxy views do not request a second login.

Repeated failed logins are rate-limited by the Control Center.

## Network/security architecture

Hermes and OpenClaw remain loopback backends. They are not directly bound to the LAN.

```text
LAN Browser
    |
    | one login
    v
Laptop IP :8088
Auto Agent Control Center
    |
    +-------------------------+
    |                         |
    v                         v
Nginx authenticated proxy   Unified Chat Router
    |                         |
    +--> Hermes Dashboard     +--> @hermes --> hermes -z
    |    127.0.0.1:9119       |
    |                         +--> @openclaw --> OpenClaw /v1/chat/completions
    +--> OpenClaw Control UI
         127.0.0.1:18789
              |
              v
        Ollama GPU gateway
              |
              v
        NVIDIA GPU server
```

OpenClaw is configured for a narrowly-scoped same-host trusted reverse proxy:

- Gateway stays `loopback`
- trusted proxy is only `127.0.0.1`
- proxy identity header is overwritten by Nginx
- external browser access must pass Control Center login first
- Chat Completions HTTP endpoint is enabled for the Unified Chat router

Hermes Dashboard also remains on loopback and is exposed only through the authenticated Nginx hop.

If UFW is already active, the installer adds LAN-subnet-only rules for the control ports. The installer does not silently enable UFW when it is disabled.

> Current Control Center LAN access uses HTTP. Authentication prevents unauthenticated use, but HTTP does not protect credentials/session traffic against an attacker capable of sniffing or modifying the LAN. HTTPS/mTLS should be used for untrusted networks or cross-site deployment.

## Ports

| Port | Purpose | Direct backend bind |
|---|---|---|
| `8088` | Unified Control Center | Nginx on laptop LAN IP |
| `9119` | Hermes view behind shared login | Hermes backend stays `127.0.0.1` |
| `18789` | OpenClaw view behind shared login | OpenClaw backend stays `127.0.0.1` |
| `11434` | GPU inference gateway on GPU server | Ollama stays `127.0.0.1` behind server Nginx |

Users normally enter only:

```text
http://LAPTOP_IP:8088
```

## Management commands

```bash
auto-agent center
auto-agent credentials
auto-agent status
auto-agent restart
auto-agent logs
```

## Resilient GPU discovery

Laptop discovery order:

1. explicit override
2. cached previously-working server
3. `_local-ai._tcp` mDNS
4. `/auto-agent/discovery` subnet scan
5. legacy `:11434` HTTP-401 fingerprint scan

The inference API token is not published in mDNS or discovery metadata. It is transferred through the SSH trust channel.

## Normal deployment

GPU server:

```bash
curl -fsSL https://raw.githubusercontent.com/caotiensinh/auto_agent/main/install.sh | bash
```

Laptop:

```bash
curl -fsSL https://raw.githubusercontent.com/caotiensinh/auto_agent/main/install.sh | bash
```

Then from any PC on the same LAN, open the Control Center URL printed by the laptop installer and log in.
