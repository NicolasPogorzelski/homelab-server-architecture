# LLM Inference - llama-server Backends

Local LLM inference for the AI stack. OpenWebUI on lxc230 is the only consumer: it reaches two
`llama-server` instances (llama.cpp) through their OpenAI-compatible API, a primary on the admin
desktop and an always-on fallback on vm100.

## Deployment

| Node | GPU | Runtime | Model | Context | Role |
|---|---|---|---|---|---|
| admin desktop | AMD, 20 GB | Podman Quadlet, Vulkan (RADV) | Qwen3.8-27B, UD-Q3_K_XL, with vision | 64K | primary, while the desktop is on |
| vm100 | NVIDIA, 8 GB, shared with Jellyfin | Docker Compose, CUDA 12 | Qwen3.5-9B, Q4_K_M, text only | 32K | fallback, always on |

Both run the same llama.cpp build from the official images, with the same flags apart from context
size and device: one slot (`-np 1`), flash attention, a `q8_0` KV cache, all layers on the GPU.

Router mode: each instance starts with `--models-dir` and `--models-max 1`, loads a model on the
first request that names it, and unloads it after 20 minutes idle (`--sleep-idle-seconds 1200`).
Each subdirectory of the models directory is one model; an `mmproj` projector beside it enables image
input. The GPUs hold no model until a request loads one. `/health` is answered by the router and
loads no model, so the blackbox probe does not occupy the GPU.

Verified 2026-09-29 and 2026-10-01:

| Node | VRAM idle | First request | VRAM loaded |
|---|---|---|---|
| admin desktop | unchanged | 13 s cold, 5.7 to 7.3 s warm | 15.5 GiB |
| vm100 | 3 MiB | 36.5 s after a host start, 2 to 3 s warm | 5.8 GB |

### Admin desktop

- Rootless Podman Quadlet `~/.config/containers/systemd/llama-server.container`, source
  `snippets/bazzite/llama-server.container`, installed by copying; not an Ansible node
- Starts at boot without a login: linger and GDM automatic login both start the user manager, and
  the unit hangs off `default.target`
- Models in `~/.local/share/models/`, mounted read-only; API key from the Podman secret
  `llama_api_key`
- Both render nodes are passed in because their numbering changes across boots; `-dev Vulkan0`
  selects the discrete card

### vm100

- Compose stack `docker/llama-server/` (image there), deployed by `docker_compose_update`
- Text only: an image sent to this model is refused at once (`image input is not supported`)
- CUDA kernel cache in `/mnt/vm-data/cuda-cache`, so a recreated container does not recompile
  (first request 114 s with an empty cache, 3 s with the kept one)
- Models and Docker's data root on `/mnt/vm-data`; `docker_mount_ordering` keeps Docker from
  starting without it
- The CUDA 13 image failed against the installed 580 driver; the CUDA 12 image is used

## Rollout State

Complete since 2026-10-01. Both instances serve OpenWebUI through OpenAI API connections; the former
Ollama installations on vm100 and the desktop are removed, and port 11434 is closed on both.
Verified 2026-10-01 from the OpenWebUI container with the stored keys: both models answer, warm
generation at 39.3 t/s (desktop) and 53.4 t/s (vm100), blackbox `probe_success 1`.

## Model Selection

Chosen for German and English, tool calls, structured output and image input within each card's
memory. The desktop acceptance test (2026-09-29) passed a tool call, a JSON-schema response and
reading a number from an image.

- Qwen3.8-27B in Q3, not Q4: the Q4 weights alone are 16.9 GiB and did not fit on the GPU beside the
  desktop's own use.
- Qwen3.5-9B in Q4, text only, on vm100: 5.8 GB at 32K leaves Jellyfin about 1.9 GB for transcoding.
  With the vision projector on the GPU Jellyfin kept 0.7 GB; on the CPU an image took minutes.
- `--image-min-tokens 1024` on the desktop: below it, Qwen-VL projectors misread small images.

## Why llama-server, and Why Vulkan on the Desktop

Same model file per card, warm, flash attention on (2026-09-29):

| Stack | Desktop, 27B Q3 | vm100, 9B Q4 |
|---|---|---|
| llama-server, Vulkan | 40.6 t/s | 53.2 t/s |
| llama-server, CUDA 12 | - | 60.5 t/s |
| llama.cpp, ROCm | 32.8 t/s (`llama-bench`) | - |
| Ollama, Vulkan / CUDA 13 | 26.1 t/s | 55.3 t/s |
| Ollama with bundled ROCm | aborts on model load | - |

## Access Model

- No public ingress, no LAN exposure. Both instances listen on `127.0.0.1:8080`; the tailnet reaches
  them through `tailscale serve --tcp 8080 tcp://127.0.0.1:8080`, so no service waits for a
  Tailscale address at boot ([decision](../decisions/loopback-tailscale-serve.md)).
- Every request needs the API key as bearer token (`401` without); `/health` is open.
- `tag:ai-stack` reaches both host aliases on 8080; monitoring probes vm100 only, because the desktop
  is often off ([tailscale-acl.md](../platform/tailscale-acl.md)).

## Known Issues

- The first request after 20 idle minutes waits for the model load (see the table above).
- While the desktop is off, OpenWebUI has no model that reads images, and still lists the desktop's
  model until a message fails.
- On the desktop llama.cpp logs `failed to fit params to free device memory` and loads fully on the
  GPU anyway; nothing spills to system memory.
- Scheduled or automated tasks target vm100 only; a request to the desktop during a game loads
  15.5 GiB into the GPU the game uses.

## Failure Impact

- Desktop off or failed: OpenWebUI answers from vm100 with the smaller model.
- vm100 backend failed: the desktop carries all requests while on; `ServiceDown` fires for the probe.
- Both failed: inference requests fail; chats and settings are unaffected. Check
  `systemctl --user status llama-server` on the desktop, `docker compose ps` in
  `/opt/docker/llama-server` on vm100, then `tailscale serve status` on each.

## Related Documents

- [vm100](../nodes/vm100.md)
- [OpenWebUI](./openwebui.md)
