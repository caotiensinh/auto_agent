# Architecture

## Goal

Deploy a small local AI cluster with one Ubuntu laptop as the control plane and one Ubuntu NVIDIA workstation as the inference plane.

## Components

```text
User / Messaging
      │
      ▼
OpenClaw Gateway
      │
      ├── orchestration / sessions / messaging
      │
      └── native Ollama API (/api/*)

Hermes Agent
      │
      ├── technical execution / coding / SSH / MCP
      │
      └── OpenAI-compatible API (/v1/*)

Both clients
      │
      ▼
Authenticated Nginx LAN Gateway
      │
      ▼
Ollama 127.0.0.1:11434
      │
      ▼
NVIDIA GPU
```

## Discovery

The GPU server advertises an Avahi service:

```text
_local-ai._tcp
```

Published metadata contains only non-secret bootstrap information:

- SSH username
- selected model
- context size
- API capability marker

The API token is never sent through mDNS.

## Pairing

The laptop discovers the GPU server through mDNS and establishes SSH key trust. The API token is then retrieved from a mode-0600 file over SSH.

This gives the deployment a real trust channel instead of broadcasting credentials over the LAN.

## API routing

Hermes uses:

```text
http://<gpu-host>:11434/v1
```

OpenClaw uses:

```text
http://<gpu-host>:11434
```

This difference is intentional. OpenClaw uses Ollama's native API for tool-calling compatibility, while Hermes uses an OpenAI-compatible endpoint.

## Responsibility boundaries

### OpenClaw

- user/channel gateway
- messaging
- orchestration
- sessions
- conservative automation

### Hermes

- coding and technical tasks
- shell/SSH/MCP workflows
- specialist execution

### Nginx

- LAN exposure boundary
- source subnet allowlist
- bearer authentication
- reverse proxy

### Ollama

- local model runtime
- no direct LAN binding

### GPU server

- model storage
- inference
- NVIDIA runtime

### Laptop

- control plane
- agent UI and tools
- no model weights required locally

## Scale-out direction

The initial design intentionally keeps one inference server. A future version can replace the single Ollama backend with an inference router and multiple Ollama/vLLM workers without changing the control-plane concept.
