# auto_agent

One-command local AI cluster deployment for Ubuntu.

The same command is used on both machines:

```bash
curl -fsSL https://raw.githubusercontent.com/caotiensinh/auto_agent/main/install.sh | bash
```

Run it on the **Ubuntu NVIDIA GPU PC first**, then run the exact same command on the **Ubuntu laptop**.

## What it deploys

```text
Ubuntu Laptop / Control Plane
├── OpenClaw Gateway
│   ├── messaging / orchestration
│   ├── Ollama native API: /api/*
│   └── conservative default tool policy
├── Hermes Agent
│   ├── technical execution / coding / SSH / MCP
│   └── OpenAI-compatible API: /v1/*
└── mDNS + SSH secure pairing
          │
          │ LAN
          ▼
Ubuntu NVIDIA GPU / Inference Plane
├── Nginx authenticated AI gateway
│   ├── automatic LAN IP/subnet detection
│   ├── Bearer token authentication
│   └── LAN ACL
├── Ollama bound to 127.0.0.1 only
├── qwen3.5:9b by default
└── NVIDIA GPU
```

## Automatic role selection

`install.sh` detects the machine role automatically:

- working NVIDIA GPU / NVIDIA PCI device → `server`
- otherwise → `client`

You can override it:

```bash
curl -fsSL https://raw.githubusercontent.com/caotiensinh/auto_agent/main/install.sh | ROLE=server bash
```

or:

```bash
curl -fsSL https://raw.githubusercontent.com/caotiensinh/auto_agent/main/install.sh | ROLE=client bash
```

## GPU server — automatic tasks

The server installer automatically:

1. verifies Ubuntu and NVIDIA driver health with `nvidia-smi`;
2. installs required packages;
3. installs/updates Ollama;
4. binds Ollama to `127.0.0.1:11434` only;
5. configures a 65,536-token default context;
6. pulls the selected model;
7. detects the active LAN interface, IP and CIDR;
8. generates a random 256-bit API token;
9. configures Nginx as an authenticated LAN gateway;
10. restricts Nginx to the detected LAN subnet;
11. enables SSH;
12. advertises `_local-ai._tcp` over mDNS/Avahi;
13. stores client bootstrap metadata with mode `0600`;
14. adds narrow UFW rules when UFW is already active;
15. verifies both Ollama native and OpenAI-compatible APIs.

The API token is **not** published through mDNS and is **not** printed to the terminal.

## Laptop — automatic tasks

The laptop installer automatically:

1. installs mDNS and SSH prerequisites;
2. discovers the GPU server through `_local-ai._tcp`;
3. learns server hostname/IP/port/model automatically;
4. creates an SSH key if one does not exist;
5. establishes SSH trust;
6. retrieves the generated API credential over SSH;
7. tests both remote API transports;
8. installs/updates Hermes Agent non-interactively;
9. configures Hermes to use the remote `/v1` endpoint;
10. installs/updates OpenClaw non-interactively;
11. configures OpenClaw to use Ollama native `/api/*` transport;
12. selects the discovered model;
13. installs/restarts the OpenClaw Gateway service;
14. verifies the provider and runs OpenClaw doctor.

### First pairing

If SSH key trust does not already exist, the laptop may ask for the **GPU server Ubuntu account password once** while `ssh-copy-id` establishes the trust relationship.

This is intentional. Securely transferring a generated secret between two previously unrelated machines requires an existing trust anchor or one human pairing step.

After pairing, reruns are automatic.

## Defaults

| Setting | Default |
|---|---|
| Model | `qwen3.5:9b` |
| Context | `65536` |
| Gateway port | `11434` |
| Ollama backend | `127.0.0.1:11434` |
| Discovery | `_local-ai._tcp` |
| OpenClaw tool profile | `messaging` |
| OpenClaw heartbeat | disabled (`0m`) |

## Model override

Because a pipe has separate process environments, set deployment variables on the `bash` side:

```bash
curl -fsSL https://raw.githubusercontent.com/caotiensinh/auto_agent/main/install.sh | MODEL=qwen3.5:27b bash
```

Larger context:

```bash
curl -fsSL https://raw.githubusercontent.com/caotiensinh/auto_agent/main/install.sh | CONTEXT_LENGTH=131072 bash
```

Force server and select a model:

```bash
curl -fsSL https://raw.githubusercontent.com/caotiensinh/auto_agent/main/install.sh | ROLE=server MODEL=qwen3.5:27b bash
```

## Rotate API token

Run on the GPU server:

```bash
curl -fsSL https://raw.githubusercontent.com/caotiensinh/auto_agent/main/install.sh | ROLE=server ROTATE_TOKEN=1 bash
```

Then rerun the standard command on the laptop so Hermes and OpenClaw obtain the new credential over SSH.

## After deployment

Hermes:

```bash
hermes
```

OpenClaw status:

```bash
openclaw status
```

OpenClaw dashboard:

```bash
openclaw dashboard
```

GPU status:

```bash
nvidia-smi
ollama ps
```

## Files

```text
.
├── install.sh
├── scripts/
│   ├── server.sh
│   └── client.sh
├── docs/
│   ├── ARCHITECTURE.md
│   └── SECURITY.md
└── README.md
```

## Security model

The design intentionally separates responsibilities:

- **OpenClaw**: gateway, messaging and orchestration;
- **Hermes**: technical/agent execution;
- **Nginx**: authenticated LAN inference gateway;
- **Ollama**: localhost-only inference service;
- **GPU server**: inference plane;
- **laptop**: control plane.

OpenClaw starts with the `messaging` tool profile and heartbeat disabled. Host shell/file access is not enabled automatically.

See [docs/SECURITY.md](docs/SECURITY.md) for details.

## Important deployment note

The convenience command executes code from the current `main` branch. For production fleets, pin deployments to a reviewed release tag or commit SHA before mass rollout.
