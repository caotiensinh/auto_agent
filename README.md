# auto_agent

One-command, inventory-first deployment for a local AI control plane using Hermes + OpenClaw + a remote Ollama GPU server.

## Canonical one-command install

During active development, use the cache-busting form below so `raw.githubusercontent.com` cannot hand the machine an older bootstrap from CDN cache:

```bash
curl -fsSL -H 'Cache-Control: no-cache' "https://raw.githubusercontent.com/caotiensinh/auto_agent/main/install.sh?$(date +%s)" | bash
```

Run the same command on the NVIDIA Ubuntu PC first, then on the Ubuntu laptop.

A correct current bootstrap prints:

```text
AUTO_AGENT BOOTSTRAP
Version : 0.5.0
```

On a laptop it must then show all three phases:

```text
CLIENT PHASE 1/3 — agent + GPU connectivity reconciliation
CLIENT PHASE 2/3 — boot persistence + loopback agent services
CLIENT PHASE 3/3 — authenticated unified LAN Control Center
```

If a laptop log ends immediately after `AUTO_AGENT LAPTOP READY` and never shows phase 2/3, that run used an old cached bootstrap and did not install the Control Center.

## Core rule

```text
Inventory → Compare → Reuse healthy components → Install only missing parts → Configure → Verify
```

The installer does not blindly reinstall NVIDIA drivers, Ollama, models, Hermes, OpenClaw, Node, or system packages.

## GPU server

The server inventories Ubuntu/kernel, NVIDIA GPU model(s), driver version, VRAM, NVIDIA packages, Ollama version, installed models, context windows and model capabilities before making changes.

Healthy GPU/driver/Ollama components are reused. Existing compatible tool-capable models are reused. A fallback model is downloaded only when no installed model satisfies policy.

Default fallback:

```text
qwen3.5:9b
```

## Laptop

The laptop reuses existing Hermes/OpenClaw/Node installations, discovers the GPU server, retrieves the inference credential through SSH, verifies real remote inference, and reconciles both agents.

Boot-persistent components use systemd user services plus `loginctl linger=yes`:

```text
Hermes Gateway
Hermes Dashboard
OpenClaw Gateway
Auto Agent Control Center
```

## One Unified Control Center

After client deployment, users normally enter only:

```text
http://LAPTOP_IP:8088
```

A different PC on the same LAN needs only a web browser. Nothing else needs to be installed on that PC.

The common menu is:

```text
Unified Chat | Hermes | OpenClaw | Status
```

The native Hermes and OpenClaw pages keep a common navigation layer through the authenticated reverse proxy, so users can switch back to Auto Agent, Hermes, or OpenClaw without typing another address.

OpenClaw deliberately sends `frame-ancestors 'none'` for its Control UI. `auto_agent` therefore does not weaken that CSP just to force the UI into an iframe. Native interfaces are opened as authenticated top-level pages while preserving their upstream browser security headers.

### Unified Chat routing

Explicit routing:

```text
@hermes check this Ubuntu network problem
@openclaw send a notification through the configured channel
```

- `@hermes` → Hermes one-shot agent execution (`hermes -z`).
- `@openclaw` → OpenClaw Gateway Chat Completions endpoint.
- `@auto` or `Auto` mode → lightweight task router.

Default Auto routing:

- code / shell / SSH / Linux / network / security / diagnostics → Hermes
- messaging / channels / scheduling / notifications / orchestration → OpenClaw

The selected agent is shown with every Unified Chat response.

## Single login

The first Control Center installation creates credentials automatically:

```text
username: admin
password: generated random secret
```

Credentials are stored mode `0600` under:

```text
~/.config/auto_agent/control.env
```

They are reused on later installer runs.

Show credentials locally on the laptop:

```bash
auto-agent credentials
```

Open the center locally:

```bash
auto-agent center
```

The session cookie is host-scoped, so the authenticated native Hermes/OpenClaw proxy pages do not request a second login. Failed login attempts are rate-limited per originating client IP.

## Network/security architecture

The agent backends remain loopback-only:

```text
LAN Browser
    |
    | login once
    v
Laptop :8088
Auto Agent Control Center
    |
    +--> Unified Chat Router
    |      +--> @hermes   --> hermes -z
    |      +--> @openclaw --> OpenClaw /v1/chat/completions
    |
    +--> authenticated native navigation
           +--> Nginx :9120  --> Hermes 127.0.0.1:9119
           +--> Nginx :18790 --> OpenClaw 127.0.0.1:18789
                                      |
                                      v
                               Ollama GPU gateway
                                      |
                                      v
                               NVIDIA GPU server
```

Security boundaries:

- Hermes stays on `127.0.0.1:9119`.
- OpenClaw stays on `127.0.0.1:18789`.
- Nginx is the only browser-facing hop.
- Nginx enforces the detected LAN CIDR even when UFW is disabled.
- If UFW is already active, matching LAN-only rules are also added.
- Nginx overwrites client-address and trusted identity headers rather than accepting browser-supplied values.
- OpenClaw trusts only same-host proxy source `127.0.0.1` with explicit `allowLoopback`.
- OpenClaw trusted-proxy configuration is applied atomically and validated before restart.
- Hermes requests are translated back to loopback Host/Origin at the backend rather than exposing its management server directly.

> LAN access currently uses HTTP. Login prevents unauthenticated use, but HTTP does not protect credentials/session traffic from an attacker capable of sniffing or modifying that LAN. Use HTTPS/mTLS or a trusted overlay network for untrusted networks or cross-site access.

## Ports

| Port | Purpose | Listener/backend |
|---|---|---|
| `8088` | Unified Control Center | Nginx LAN entry |
| `9120` | Hermes native view behind shared login | Nginx → `127.0.0.1:9119` |
| `18790` | OpenClaw native view behind shared login | Nginx → `127.0.0.1:18789` |
| `9119` | Hermes Dashboard backend | loopback only |
| `18789` | OpenClaw Gateway backend | loopback only |
| `11434` | GPU inference gateway on GPU server | server Nginx → Ollama loopback |

Users normally need only port `8088`; the native-view ports are selected automatically by the common menu.

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

The inference API token is never published through mDNS or discovery metadata. It is transferred through the SSH trust channel.

## Normal deployment

GPU server:

```bash
curl -fsSL -H 'Cache-Control: no-cache' "https://raw.githubusercontent.com/caotiensinh/auto_agent/main/install.sh?$(date +%s)" | bash
```

Laptop:

```bash
curl -fsSL -H 'Cache-Control: no-cache' "https://raw.githubusercontent.com/caotiensinh/auto_agent/main/install.sh?$(date +%s)" | bash
```

Then open the URL printed by the laptop installer from any browser on the same LAN and log in.
