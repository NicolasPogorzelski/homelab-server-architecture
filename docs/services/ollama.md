# Ollama — Inference Backend

## Purpose

Ollama provides local LLM inference for the AI stack.
It serves as the backend for OpenWebUI (CT230) and future agentic workflows.

## Deployment

Two inference nodes are planned:

| Node | Hardware | Role | Tag |
|---|---|---|---|
| VM100 | NVIDIA RTX 2070 (8GB VRAM) | Backup | `tag:tier2` |
| Gaming PC | AMD RX 7900 XT (20GB VRAM) | Primary | `tag:admin` |

## VM100 — Current State

- Installation: native systemd service (`/etc/systemd/system/ollama.service`)
- Override: `/etc/systemd/system/ollama.service.d/override.conf`
- Bind address: Tailscale IP only (`<tailscale-ip-vm100>:11434`)
- Model: `qwen3:8b-q4_K_M`
- GPU: NVIDIA RTX 2070, driver 535, CUDA 12.2

## Model Selection

| Node | Model | VRAM Usage | Context |
|---|---|---|---|
| VM100 (backup) | `qwen3:8b-q4_K_M` | ~5GB | 4096 (default) |
| Gaming PC (primary) | `qwen3:32b-q4_K_M` | ~20GB | TBD |

Rationale: Qwen3 leads the 8B class in multilingual performance and reasoning.
Optimized for single-GPU deployment with up to 128K token context support.

## Access Model (Zero Trust)

- No public ingress
- No LAN exposure
- Ollama binds exclusively to the Tailscale IP (`<tailscale-ip-vm100>:11434`)
- Network policy enforced via Tailscale ACL (node tags + ACL JSON)
- See: [docs/platform/tailscale-acl.md](../platform/tailscale-acl.md)

Allowed sources (port 11434):
- `tag:ai-stack` — OpenWebUI (CT230)
- `tag:admin` — operator access for management

## Known Issues / Open Items

- `OLLAMA_HOST` must be set explicitly when using the CLI on VM100
  (because the service binds to Tailscale IP, not loopback):
  `OLLAMA_HOST=<tailscale-ip-vm100>:11434 ollama <command>`
- Default context window is 4096 tokens — increase via
  `OLLAMA_NUM_CTX` for RAG workloads (planned)
- Gaming PC (primary) not yet configured — ROCm setup pending

## Related Documents

- [VM100 Node](../nodes/vm100.md)
- [OpenWebUI Service](./openwebui.md)
- [Tailscale ACL](../platform/tailscale-acl.md)
