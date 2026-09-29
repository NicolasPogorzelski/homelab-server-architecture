# LLM Inference - llama-server Backends

## Purpose

Local LLM inference for the AI stack. OpenWebUI (CT230) is the only consumer: it reaches two
`llama-server` instances from llama.cpp through their OpenAI-compatible API, a primary on the admin
desktop and an always-on fallback on vm100.

## Deployment

| Node | GPU | Runtime | Model | Context | Role |
|---|---|---|---|---|---|
| admin desktop (Bazzite) | AMD RX 7900 XT, 20 GB | Podman Quadlet, Vulkan (RADV) | Qwen3.8-27B, UD-Q3_K_XL, with vision | 64K | Primary, runs when the desktop is on |
| vm100 | NVIDIA RTX 2070 SUPER, 8 GB, shared with Jellyfin | Docker Compose, CUDA 12 | Qwen3.5-9B, Q4_K_M, with vision | 32K | Fallback, always on |

Both run the same llama.cpp build, `b11243`, from the official images
(`server-vulkan-b11243`, `server-cuda-b11243`), with the same flags apart from context size and
device: flash attention on, a `q8_0` KV cache, all layers on the GPU.

**Router mode, no model resident after start.** Each instance starts with `--models-dir` and
`--models-max 1` instead of a fixed model. It loads a model on the first request that names it and
unloads it again after 20 minutes without a request (`--sleep-idle-seconds 1200`). Each
subdirectory of the models directory is one model, named after the directory, with its `mmproj`
vision projector beside it. On the desktop this is what allows a reboot straight into a game: the
GPU carries nothing of the LLM until someone asks. Measured on 2026-09-29:

| Node | VRAM after start | Wake on first request | VRAM loaded |
|---|---|---|---|
| admin desktop | unchanged (desktop only) | 13 s from a cold page cache, 5.7 s warm | 15.5 GiB, 93 MiB in GTT |
| vm100 (Vulkan test build) | 4 MiB | 5 s | 6.9 GiB; 5.96 GB with the CUDA build at the same context |

`/health` is answered by the router itself and does not load a model, which is what lets the
blackbox probe run against it without keeping the GPU occupied.

### Admin desktop

- Unit: rootless Podman Quadlet `~/.config/containers/systemd/llama-server.container`, source
  [`snippets/bazzite/llama-server.container`](../../snippets/bazzite/llama-server.container)
- Starts without a login because linger is enabled for the user (`loginctl enable-linger`); the
  unit hangs off `default.target`. Disabling linger silently turns the primary backend into one
  that exists only while somebody is logged in.
- Models: `~/.local/share/models/qwen3.8-27b/`, mounted read-only
- API key: Podman secret `llama_api_key`, passed as `LLAMA_API_KEY`
- Both render nodes are passed to the container, because their numbering is not stable across
  boots; `-dev Vulkan0` selects the discrete card. Measured through the DRM `fdinfo` of the model
  process: 15.5 GiB on the 7900 XT, 12 KiB on the integrated GPU.
- Not an Ansible node: the Quadlet is installed by copying the snippet

### vm100

- Compose stack [`docker/llama-server/`](../../docker/llama-server/), deployed by the
  `docker-compose-update` role like the other two stacks on the node
- Models and Docker's data root on the auxiliary disk (`/mnt/vm-data`); `docker_mount_ordering`
  makes Docker refuse to start without that mount, so a slow disk cannot send image layers onto the
  system disk and its thin pool
- NVIDIA driver 580 (`nvidia-driver-580-server`). The CUDA 12 image is used rather than
  `server-cuda13`: the CUDA 13 build failed against this driver in testing.

## Rollout State

The desktop half is live. The vm100 half is deployed from this repository and replaces the native
Ollama 0.19 service, which stays the fallback until the new stack has passed its checks.

| Step | State |
|---|---|
| Desktop: Quadlet running, all checks passed, `tailscale serve` on 8080 | Done 2026-09-29 |
| vm100: Docker data root moved to `/mnt/vm-data`, stack deployed, `tailscale serve` on 8080 | Pending |
| ACL Rule 6 and the monitoring grant switched to 8080 | Pending |
| OpenWebUI: two OpenAI connections replace the Ollama connections | Pending |
| vm100: native Ollama removed, together with its KE-18 instance | Pending, after OpenWebUI |
| Desktop: cold boot proven | Pending, needs someone at the machine |

## Model Selection

Chosen for German and English, tool calls, structured output and image input, within each card's
memory. The acceptance test on the desktop, 2026-09-29, passed a tool call, a JSON-schema response
and reading a number from an image, at 40.4 tokens/s.

- **Qwen3.8-27B in Q3** rather than Q4: the Q4 weights alone are 16.9 GiB and ran only 78 to 84 %
  on the GPU next to the desktop's own use. The Unsloth dynamic Q3 fits completely with 64K context.
- **Qwen3.5-9B in Q4** on vm100: 5.96 GB at 32K context, which leaves Jellyfin 2.2 GB for
  transcoding.

## Why llama-server, and Why Vulkan on the Desktop

Measured 2026-09-29 with the same model file on each card, warm model, flash attention on.

| Stack | Desktop, 27B Q3 | vm100, 9B Q4 |
|---|---|---|
| llama-server, Vulkan | 40.6 t/s | 53.2 t/s |
| llama-server, CUDA 12 | - | 60.5 t/s |
| llama.cpp, ROCm 7.1.1 | 32.8 t/s (`llama-bench`) | - |
| Ollama 0.35 | 26.1 t/s (Vulkan) | 55.3 t/s (CUDA 13) |
| Ollama with its bundled ROCm 7.2.1 | aborts on model load | - |
| Ollama 0.19, the previous state | - | 16.9 t/s, partly on the CPU |

Ollama costs 35 % on the desktop and 9 % on vm100, so the loss sits in its Vulkan path rather than
in Ollama as a whole. The ROCm abort (`Memory critical error ... Memory in use`) appeared after the
desktop's kernel and GPU firmware updates; the same Ollama image had loaded models on the older
kernel in July, and Fedora's ROCm 7.1.1 runs on the current one. Vulkan is used anyway because it
generates faster on this card.

## Access Model (Zero Trust)

- No public ingress, no LAN exposure
- Both instances listen on `127.0.0.1:8080` only. The tailnet reaches them through
  `tailscale serve --tcp 8080 tcp://127.0.0.1:8080`, so no service waits for a Tailscale address at
  boot - the failure class of [KE-18](../platform/known-errors.md#ke-18). See the
  [loopback + Tailscale Serve decision](../decisions/loopback-tailscale-serve.md).
- Every request needs the API key as a bearer token; without it the API answers `401`. `/health`
  is open.
- ACL Rule 6 grants `tag:ai-stack` the two host aliases on 8080; monitoring reaches vm100 only,
  because the desktop is off much of the time and would page for it.
  See [tailscale-acl.md](../platform/tailscale-acl.md).

| Node | Listens on | Tailnet entry | Allowed sources |
|---|---|---|---|
| admin desktop | `127.0.0.1:8080` | `bazzite:8080` via `tailscale serve` | `tag:ai-stack` |
| vm100 | `127.0.0.1:8080` | `gpu-vm:8080` via `tailscale serve` | `tag:ai-stack`, `tag:monitoring` |

## Configuration Management

- vm100: the Compose file and `.env.example` in [`docker/llama-server/`](../../docker/llama-server/),
  the stack list in `host_vars/vm100.yml`, the mount requirement through `docker_mount_ordering`.
  The `.env` holding the key is created on the node (`chmod 600`) and never committed.
- Admin desktop: the Quadlet snippet; the Podman secret is created on the machine.
- Monitoring: the `blackbox-http` job probes `http://<vm100>:8080/health`.

## Known Issues / Open Items

- The first request after 20 idle minutes waits for the model to load, 5 to 13 s.
- llama.cpp logs `failed to fit params to free device memory` on the desktop and loads anyway,
  because `-ngl 99` is set. Measured through `fdinfo`: nothing spills to system memory. The estimate
  is conservative, not the allocation.
- OpenWebUI still lists the desktop's model while the desktop is off; the error surfaces only when
  a message is sent.
- Scheduled or automated tasks should target vm100 only. A request to the desktop during a game
  loads 15.5 GiB into the GPU the game is using.

## Failure Impact

If the admin desktop is off or its backend fails:
- OpenWebUI answers from vm100 with the smaller model
- No data loss

If vm100's backend fails:
- The desktop carries all requests while it is on; when it is off, inference is unavailable
- `ServiceDown` fires for the vm100 probe
- No data loss

If both fail:
- Every inference request from OpenWebUI fails; chats, uploads and settings are unaffected
- Recovery: `systemctl --user status llama-server` on the desktop, `docker compose ps` in
  `/opt/docker/llama-server` on vm100, then `tailscale serve status` on each

## Related Documents

- [VM100 Node](../nodes/vm100.md)
- [OpenWebUI Service](./openwebui.md)
- [Tailscale ACL](../platform/tailscale-acl.md)
- [llama-server Quadlet (desktop)](../../snippets/bazzite/llama-server.container)
- [llama-server Compose stack (vm100)](../../docker/llama-server/)
