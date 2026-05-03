# Runbook: Migrate Docker engine data root to Aux1TB

## Problem

By default, Docker stores its data root (`/var/lib/docker`) and containerd images
(`/var/lib/containerd`) on the root disk. On Proxmox LXCs backed by `local-lvm`,
these directories grow with every pulled image and accumulate layer caches over time.
This exhausts the SSD thin-pool without the growth being visible in `df` output.

This runbook documents how to relocate the Docker engine data root and containerd
image store from the root disk to an Aux1TB mount point. Run it on any LXC where
the data root has not been configured on Aux1TB from the start.

**Affected nodes (migrated 2026-04-30):** LXC200, LXC211, LXC220, LXC230.
New nodes must follow the [Adding a New Service](../../CLAUDE.md) checklist instead —
this runbook is for retroactive migration only.

## Preconditions

- SSH access to the target LXC (via Proxmox host: `pct exec <ctid> -- bash`)
- Aux1TB mount point is online and mounted
  ```bash
  mountpoint -q /mnt/aux1TB/<service> && echo "mounted" || echo "NOT mounted"
  ```
- Sufficient free space on Aux1TB for current Docker data
  ```bash
  du -sh /var/lib/docker /var/lib/containerd
  df -h /mnt/aux1TB/<service>
  ```
- Target subdirectories exist (create if missing):
  ```bash
  mkdir -p /mnt/aux1TB/<service>/docker-data
  mkdir -p /mnt/aux1TB/<service>/containerd
  ```

## Node-specific Aux1TB paths

| Node | Mount point (inside LXC) | docker-data | containerd |
|---|---|---|---|
| LXC200 | `/data` | `/data/docker-data` | `/data/containerd` |
| LXC211 | `/var/lib/paperless` | `/var/lib/paperless/docker-data` | `/var/lib/paperless/containerd` |
| LXC220 | `/var/lib/calibreweb` | `/var/lib/calibreweb/docker-data` | `/var/lib/calibreweb/containerd` |
| LXC230 | `/var/lib/openwebui` | `/var/lib/openwebui/docker-data` | `/var/lib/openwebui/containerd` |

Replace `<DOCKER_DATA>` and `<CONTAINERD_ROOT>` in the commands below with the
correct paths for the target node.

## Commands

All commands run inside the target LXC.

**1. Stop the Docker stack**

```bash
cd /opt/<service>
docker compose down
```

**2. Stop Docker daemon and containerd**

```bash
systemctl stop docker docker.socket containerd
```

**3. Move existing data to Aux1TB**

```bash
rsync -a /var/lib/docker/ <DOCKER_DATA>/
rsync -a /var/lib/containerd/ <CONTAINERD_ROOT>/
```

Verify the transfer before removing the originals:

```bash
du -sh /var/lib/docker <DOCKER_DATA>
du -sh /var/lib/containerd <CONTAINERD_ROOT>
```

**4. Remove original directories**

```bash
rm -rf /var/lib/docker
rm -rf /var/lib/containerd
```

**5. Configure Docker data root**

`/etc/docker/daemon.json` (create or extend):

```json
{
  "data-root": "<DOCKER_DATA>"
}
```

**6. Configure containerd root**

In `/etc/containerd/config.toml`, set:

```toml
root = "<CONTAINERD_ROOT>"
```

If the file does not exist, generate the default and then edit:

```bash
containerd config default > /etc/containerd/config.toml
```

**7. Start services**

```bash
systemctl start containerd
systemctl start docker
docker compose up -d
```

---

## Verification

```bash
docker info | grep "Docker Root Dir"
```

Expected: path matches `<DOCKER_DATA>`.

```bash
docker compose ps
```

Expected: all services `Up` with no restart loops.

```bash
df -h /mnt/aux1TB/<service>
```

Confirms disk usage has shifted to Aux1TB. The root disk (`/`) should not grow
further with image pulls.

---

## Failure Modes

| Symptom | Likely Cause | Action |
|---|---|---|
| `containerd` fails to start | Wrong `root` path in `config.toml` or directory missing | Verify path exists; check `journalctl -u containerd` |
| `dockerd` fails to start | Invalid JSON in `daemon.json` or path missing | Validate with `python3 -m json.tool /etc/docker/daemon.json`; check `journalctl -u docker` |
| Images missing after restart | `rsync` was incomplete or wrong source path | Re-run `rsync` from `/var/lib/docker/` to `<DOCKER_DATA>/`; check `du -sh` on both sides |
| Container exits immediately | Named volumes not migrated | Inspect `docker volume ls`; data should be present if `rsync` was complete |
| Aux1TB not mounted at boot | `mp` entry missing in Proxmox LXC config | Verify with `pct config <ctid>`; check `mountpoint` status inside LXC |

---

## Notes

- Docker data root is set in `/etc/docker/daemon.json` via the `data-root` key.
  See: [Docker docs — daemon configuration](https://docs.docker.com/reference/cli/dockerd/#daemon-configuration-file)
- containerd root is set in `/etc/containerd/config.toml` via the top-level `root` key.
  See: [containerd config reference](https://github.com/containerd/containerd/blob/main/docs/man/containerd-config.toml.5.md)
- After migration, run `fstrim -av` on the Proxmox host to reclaim freed thin-pool space.
- See: [LXC200 node doc](../../docs/nodes/lxc200.md)
- See: [LXC211 node doc](../../docs/nodes/lxc211.md)
- See: [LXC220 node doc](../../docs/nodes/lxc220.md)
- See: [LXC230 node doc](../../docs/nodes/lxc230.md)
