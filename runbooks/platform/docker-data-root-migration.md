# Runbook: Migrate the Docker data root of an LXC to the aux-disk

- **Use when:** an LXC keeps `/var/lib/docker` and `/var/lib/containerd` on its root disk, which
  lives in the `local-lvm` thin pool.
- **Duration:** 20-40 minutes per LXC, mostly copy time; the stack is down for all of it.
- **Risk:** an incomplete copy loses images and named volumes; deleting the originals too early
  makes that permanent.
- **Last exercised:** 2026-04-30, pass (lxc200, lxc211, lxc220, lxc230 migrated with an earlier
  version of these steps).

Image layers and caches grow with every pull. On a thin-pool root disk that growth fills the pool
without showing in the guest's `df` ([KE-7](../../docs/platform/known-errors.md#ke-7)). The current
target is the host's aux-disk, bind-mounted into the LXC; that disk is degrading
([KE-13](../../docs/platform/known-errors.md#ke-13)).

| Node | Mount point in the LXC | `<DOCKER_DATA>` | `<CONTAINERD_ROOT>` |
|---|---|---|---|
| lxc200 | `/data` | `/data/docker-data` | `/data/containerd` |
| lxc211 | `/var/lib/paperless` | `/var/lib/paperless/docker-data` | `/var/lib/paperless/containerd` |
| lxc220 | `/var/lib/calibreweb` | `/var/lib/calibreweb/docker-data` | `/var/lib/calibreweb/containerd` |
| lxc230 | `/var/lib/openwebui` | `/var/lib/openwebui/docker-data` | `/var/lib/openwebui/containerd` |

Commands run inside the LXC (`pct enter <ctid>`) unless marked as host.

## Preconditions

- The aux-disk mount point is attached (`pct config <ctid>` shows the `mp` entry) and mounted:
  `findmnt <mount point>` prints the bind source under `/mnt/aux-disk`.
- Enough free space on the target:
  ```bash
  du -sh /var/lib/docker /var/lib/containerd
  df -h <mount point>
  ```
- The root disk can hold the old copy until step 9; nothing is freed before then.
- A recent vzdump of the LXC exists ([guest-backup-restore.md](guest-backup-restore.md)).

## Steps

1. Record the running containers and stop the stack.
   ```bash
   docker ps --format '{{.Names}} {{.Image}}' > /root/containers-before.txt
   cd /opt/<service> && docker compose down
   ```
   Check: `docker ps` lists nothing.

2. Stop the engine.
   ```bash
   systemctl stop docker docker.socket containerd
   ```
   Check: `systemctl is-active docker containerd` prints `inactive` twice.

3. Back up the daemon configuration. This makes steps 6 and 7 reversible.
   ```bash
   cp -a /etc/docker/daemon.json /etc/docker/daemon.json.bak 2>/dev/null || true
   cp -a /etc/containerd/config.toml /etc/containerd/config.toml.bak 2>/dev/null || true
   ```
   Check: each file that existed has a `.bak` next to it.

4. Copy both trees, preserving hard links, ACLs, xattrs and numeric IDs.
   ```bash
   mkdir -p <DOCKER_DATA> <CONTAINERD_ROOT>
   rsync -aHAX --numeric-ids /var/lib/docker/ <DOCKER_DATA>/
   rsync -aHAX --numeric-ids /var/lib/containerd/ <CONTAINERD_ROOT>/
   ```
   Check: a second run of each `rsync` with `-n --itemize-changes` prints nothing, and
   `du -s --apparent-size` matches between source and target.

5. Move the originals aside. A rename on the same filesystem, so it is reversible.
   ```bash
   mv /var/lib/docker /var/lib/docker.old
   mv /var/lib/containerd /var/lib/containerd.old
   ```
   Check: `ls -d /var/lib/*.old` shows both.

6. Point Docker at the new root in `/etc/docker/daemon.json` (merge with existing keys):
   ```json
   { "data-root": "<DOCKER_DATA>" }
   ```
   Check: `python3 -m json.tool /etc/docker/daemon.json` exits 0.

7. Point containerd at the new root: in `/etc/containerd/config.toml` set the top-level
   `root = "<CONTAINERD_ROOT>"`. If the file does not exist, create it first with
   `containerd config default > /etc/containerd/config.toml`.
   Check: `grep '^root' /etc/containerd/config.toml` prints the new path.

8. Start the engine and the stack.
   ```bash
   systemctl start containerd docker
   cd /opt/<service> && docker compose up -d
   ```
   Check: `docker info --format '{{.DockerRootDir}}'` prints `<DOCKER_DATA>`; `docker ps` lists the
   same containers as `/root/containers-before.txt`, all `Up`, none restarting.

9. Delete the old copies, only after the Verification section has passed.
   ```bash
   rm -rf /var/lib/docker.old /var/lib/containerd.old
   ```
   Then on the host, return the freed blocks to the thin pool:
   ```bash
   pct fstrim <ctid>
   ```
   Check: `lvs` on the host shows a lower `Data%` for the LXC's disk.

## Verification

- `docker info --format '{{.DockerRootDir}}'` is `<DOCKER_DATA>`.
- `docker compose ps` shows every service `Up` (or `healthy`) for at least five minutes.
- `docker volume ls` lists the same named volumes as before; the application shows its data (for
  lxc211, the Paperless document list and search work, which read the `paperless-data` volume).
- `docker pull` of a small image grows `<DOCKER_DATA>`, not `/`.

## Failure modes

| Symptom | Cause | Action |
|---|---|---|
| `containerd` does not start | Wrong `root` path or directory missing | `journalctl -u containerd`; fix the path |
| `dockerd` does not start | Invalid JSON in `daemon.json` | `python3 -m json.tool /etc/docker/daemon.json`; `journalctl -u docker` |
| Images or volumes missing | Copy incomplete | Roll back, rerun step 4 |
| Container exits at once | Named volume not copied, or ownership changed | Compare `docker volume ls`; `--numeric-ids` was missing; roll back |
| Data root empty after a reboot | Mount point not attached or aux-disk not mounted on the host | `pct config <ctid>`; `findmnt /mnt/aux-disk` on the host |

## Rollback

Possible until step 9.

```bash
docker compose -f /opt/<service>/docker-compose.yml down
systemctl stop docker docker.socket containerd
mv /etc/docker/daemon.json.bak /etc/docker/daemon.json          # or remove daemon.json if there was none
mv /etc/containerd/config.toml.bak /etc/containerd/config.toml  # or remove config.toml if there was none
mv /var/lib/docker.old /var/lib/docker
mv /var/lib/containerd.old /var/lib/containerd
systemctl start containerd docker
docker compose -f /opt/<service>/docker-compose.yml up -d
```

After step 9 there is no rollback; restore the LXC from its vzdump.

## Background

Service data mostly sits in bind mounts outside the data root: Paperless documents and the
Calibre-Web library on SMB shares, OpenWebUI app state and the monitoring data on the aux-disk. The
exception is named volumes, which live inside the data root and move with it: Paperless keeps
`paperless-data` and `redis-data` there. A lost data root is therefore not just a re-pull of the
pinned images in `docker/<stack>/docker-compose.yml`, which is why the originals stay until the
stack has been verified.

`data-root` is documented in the
[dockerd configuration reference](https://docs.docker.com/reference/cli/dockerd/#daemon-configuration-file),
`root` in the
[containerd configuration reference](https://github.com/containerd/containerd/blob/main/docs/man/containerd-config.toml.5.md).
Host-side `fstrim` does not reach LXC filesystems; `pct fstrim` does.
Node layout: [lxc200](../../docs/nodes/lxc200.md), [lxc211](../../docs/nodes/lxc211.md),
[lxc220](../../docs/nodes/lxc220.md), [lxc230](../../docs/nodes/lxc230.md).
