# Security

## Baseline

This project is intended for a trusted private LAN. It does not treat the LAN itself as sufficient authentication.

## Inference boundary

Ollama is configured to listen only on:

```text
127.0.0.1:11434
```

Nginx is the only LAN-facing inference endpoint.

Nginx applies two controls:

1. source network allowlisting for the detected local subnet;
2. a random 256-bit Bearer token.

## Token handling

The token is:

- generated with `openssl rand -hex 32`;
- stored as root-only state under `/etc/local-ai-gateway/token`;
- copied into a mode-0600 client bootstrap file owned by the selected server user;
- never placed in Avahi/mDNS metadata;
- never intentionally printed by the installer;
- transferred to the laptop through SSH.

Token rotation is supported by rerunning the server installer with `ROTATE_TOKEN=1`, followed by a client rerun.

## SSH trust

A newly deployed pair of machines has no cryptographic relationship by default. The client therefore creates an SSH key if needed and uses `ssh-copy-id` for first pairing.

The first pairing may require the GPU-server Ubuntu account password once. Removing this step without providing another trust anchor would require sending secrets over an unauthenticated channel, which this project intentionally avoids.

## Firewall policy

The script does not automatically enable UFW on machines where it is disabled because doing so can disrupt existing remote access or unrelated services.

When UFW is already active, the server installer adds narrow rules for:

- inference gateway TCP port from the local subnet;
- SSH TCP/22 from the local subnet;
- mDNS UDP/5353.

Nginx still enforces subnet restriction and Bearer authentication even when UFW is disabled.

## OpenClaw policy

OpenClaw is installed as the orchestration and messaging layer. The installer starts with:

```text
tools.profile = messaging
heartbeat = 0m
```

This avoids automatically granting broad host shell/file access just because messaging or orchestration is enabled.

Do not enable elevated execution or broad filesystem access for Internet-facing channels without an explicit permission model, sender allowlists, sandboxing and human approval for consequential actions.

## HTTP transport

The initial release uses authenticated HTTP on a trusted LAN. Bearer authentication protects access control, but HTTP does not encrypt traffic against an attacker already able to observe that LAN segment.

For untrusted Wi-Fi, routed multi-site networks or Internet exposure, add one of:

- WireGuard/Tailscale between control and inference planes;
- HTTPS with a trusted private CA;
- mutual TLS.

Do not expose the inference gateway directly to the public Internet.

## Supply-chain note

The convenience command:

```bash
curl -fsSL https://raw.githubusercontent.com/caotiensinh/auto_agent/main/install.sh | bash
```

executes the current `main` branch. This is convenient for development but mutable.

For production fleets, publish reviewed releases and pin deployment to a tag or immutable commit SHA. Consider signing releases and verifying checksums before execution.
