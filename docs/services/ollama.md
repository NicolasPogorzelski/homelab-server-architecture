# Ollama — Inference Backend

## Purpose

Ollama provides local LLM inference for the AI stack.
It serves as the backend for OpenWebUI (CT230) and future agentic workflows.

## Deployment

Two inference nodes are operational:

| Node | Hardware | Role | Tag |
|---|---|---|---|
| VM100 | NVIDIA RTX 2070 (8GB VRAM) | Backup | `tag:tier2` |
| Gaming PC | AMD RX 7900 XT (20GB VRAM) | Primary | `tag:admin` |

## Deployment — Current State

### VM100 (Backup)

- Installation: native systemd service (`/etc/systemd/system/ollama.service`)
- Override: `/etc/systemd/system/ollama.service.d/override.conf`
- Bind address: Tailscale IP only (`<tailscale-ip-vm100>:11434`)
- GPU: NVIDIA RTX 2070, driver 535, CUDA 12.2
- Models: `qwen3-8b-16k` (16K context via Modelfile)
- Model storage: `/mnt/vm-data/ollama/models`

### Gaming PC (Primary)

- Installation: `ollama-rocm` via pacman (CachyOS repository)
- Override: `/etc/systemd/system/ollama.service.d/override.conf`
- Bind address: Tailscale IP only (`<tailscale-ip-gaming-pc>:11434`)
- GPU: AMD RX 7900 XT (20GB VRAM), ROCm 7.2.0, gfx1100
- Models: `qwen3-32b-8k`, `qwen3-14b-64k`, `qwen3-8b-128k` (context via Modelfiles)
- Model storage: `/var/lib/ollama` (default, sufficient disk space available)
- Known: rocBLAS probe-runner crashes on startup (non-blocking, GPU recovered automatically)
- Known: ROCm inference is ~30-50% slower than CUDA on comparable hardware

## Model Selection

### VM100 (Backup)

| Model | VRAM | Context | Use Case |
|---|---|---|---|
| `qwen3-8b-16k` | ~5GB | 16K | General, RAG |

### Gaming PC (Primary)

| Model | VRAM | Context | Use Case |
|---|---|---|---|
| `qwen3-32b-8k` | ~20GB | 8K | Highest quality, short prompts |
| `qwen3-14b-64k` | ~9GB | ~40K | Long RAG sessions, agentic workflows |
| `qwen3-8b-128k` | ~5GB | 128K | Maximum context, fast responses |

### Rationale

Qwen3 is selected across all nodes for consistent behavior in the inference pipeline,
strong multilingual performance (Deutsch + English), and optimized single-GPU deployment.

Context strategy: qwen3:32b fills the full 20GB VRAM leaving minimal KV-cache headroom —
it is best suited for high-quality short-context tasks. For long RAG sessions and agentic
workflows requiring 32K–64K token context, qwen3:14b is the appropriate choice.
qwen3:8b provides maximum context (128K) and fastest responses for interactive use.

Context window note: Context is configured per model via Modelfiles.

## Access Model (Zero Trust)

- No public ingress
- No LAN exposure
- Ollama binds exclusively to the Tailscale IP on each node
- Network policy enforced via Tailscale ACL (node tags + ACL JSON)
- See: [docs/platform/tailscale-acl.md](../platform/tailscale-acl.md)

| Node | Bind Address | Allowed Sources |
|---|---|---|
| VM100 | `<tailscale-ip-vm100>:11434` | `tag:ai-stack`, `tag:admin` |
| Gaming PC | `<tailscale-ip-gaming-pc>:11434` | `tag:ai-stack`, `tag:admin` |

## Known Issues / Open Items

- `OLLAMA_HOST` must be set explicitly when using the CLI on any node
  (service binds to Tailscale IP, not loopback):
  `OLLAMA_HOST=<tailscale-ip-node>:11434 ollama <command>`
- Gaming PC: rocBLAS probe-runner crashes on startup (non-blocking, known ROCm/gfx1100 issue)
- ROCm inference is ~30-50% slower than CUDA on comparable hardware

## Future Improvements

- **Automatic backend selection:** Route inference requests based on Gaming PC
  availability and GPU load (<30% → Gaming PC, otherwise VM100). Requires a
  local proxy with health-check logic (planned for Phase 2, after Bash/Python
  proficiency).
- **Offline backend filtering:** Hide models from unavailable backends in
  OpenWebUI dropdown. Currently offline backends still appear in model selection
  — errors only surface on first message send.

## Related Documents

- [VM100 Node](../nodes/vm100.md)
- [OpenWebUI Service](./openwebui.md)
- [Tailscale ACL](../platform/tailscale-acl.md)
- [Ollama Modelfiles](../../snippets/ollama/)
