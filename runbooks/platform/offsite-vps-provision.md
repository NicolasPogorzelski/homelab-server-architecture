# Runbook: provisioning the off-site backup VPS

## Problem

The [off-site backup target decision](../../docs/decisions/offsite-backup-target.md) names a small
VPS running `rest-server` in append-only mode. Nothing exists yet. This procedure builds it by hand,
once, and stops at the point where [`backup/offsite-backup.md`](../backup/offsite-backup.md) takes
over.

By hand and not by Terraform on purpose. The Terraform track is deferred, and a backup target that
waits for a learning track is a backup target that does not exist. The machine is adopted into
Terraform state later, which is a smaller job than creating it there now.

## Preconditions

1. **An account with a European provider.** Hetzner Cloud is the working assumption in the
   decision; anything with an hourly-billed small instance and an attachable volume fits.
2. **A payment method.** Single-digit euros per month at 41 GB.
3. **An SSH key for the VPS**, distinct from the automation key on lxc250. The point of a second
   site is defeated by a credential that a compromise of the first site already holds.
4. **A decision on the DNS name**, or none - an IP address in the repository URL works and puts
   nothing in a public zone.

## Commands

Everything below runs on the VPS as root unless stated otherwise.

**1. Instance and volume.** Smallest instance; a volume sized for the data plus history. 41 GB of
source data compresses and deduplicates, so 100 GB is generous and leaves room for the retention
the server applies.

**2. Base hardening before anything is stored.**

```bash
apt-get update && apt-get -y upgrade
apt-get -y install ufw fail2ban rest-server
ufw default deny incoming
ufw allow OpenSSH
ufw enable
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
systemctl restart ssh
```

**3. Put it on the tailnet, and keep the REST port off the public internet.** This is the step that
makes the firewall rule above sufficient: the backup traffic never traverses a public port.

```bash
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up --advertise-tags=tag:offsite --ssh=false
tailscale ip -4
```

Add `tag:offsite` to the policy in the Tailscale admin console, granting vm102 and lxc250 access to
port 8000 and nothing else, and mirror it in
[`tailscale-acl.md`](../../docs/platform/tailscale-acl.md).

**4. Storage and accounts.**

```bash
mkfs.ext4 /dev/disk/by-id/<volume>          # the provider names it; never a kernel letter
mkdir -p /srv/restic
mount /dev/disk/by-id/<volume> /srv/restic
echo '/dev/disk/by-id/<volume> /srv/restic ext4 defaults,nofail 0 2' >> /etc/fstab
useradd --system --home /srv/restic --shell /usr/sbin/nologin restic
chown -R restic:restic /srv/restic
```

**5. The REST server, append-only.**

```bash
htpasswd -B -c /srv/restic/.htpasswd vm102
htpasswd -B /srv/restic/.htpasswd lxc250
chown restic:restic /srv/restic/.htpasswd && chmod 600 /srv/restic/.htpasswd
```

Unit at `/etc/systemd/system/rest-server.service`:

```ini
[Unit]
Description=restic REST server, append-only
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
User=restic
# --append-only is the control this whole target was chosen for: this listener
# can create and read snapshots and cannot remove anything, so a credential
# stolen from the homelab cannot destroy the copy it was stolen to reach.
# --private-repos keeps each account inside its own path, so a compromise of one
# source node cannot read the other's.
# The listen address is the Tailscale one: the port is never public.
ExecStart=/usr/bin/rest-server --path /srv/restic --append-only --private-repos \
  --htpasswd-file /srv/restic/.htpasswd --listen <tailscale-ip-offsite>:8000
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

```bash
systemctl enable --now rest-server
```

**6. Initialise both repositories - from here, not from the homelab.** `restic init` writes a
config object, which an append-only account is not allowed to do. This is the one operation that
belongs on the server side, and forgetting it produces a first backup run that fails with a message
about a missing repository.

```bash
sudo -u restic restic -r /srv/restic/vm102  init
sudo -u restic restic -r /srv/restic/lxc250 init
```

Record both passwords on paper, in the same envelope as the Ansible vault password. A repository
whose password is lost is indistinguishable from one that was never taken.

**7. Server-side retention**, since the clients cannot prune. A timer on the VPS, running as
`restic` with direct filesystem access rather than through the append-only listener:

```bash
sudo -u restic restic -r /srv/restic/vm102 forget \
  --keep-daily 7 --keep-weekly 5 --keep-monthly 12 --prune
```

Retention in time classes and not in a snapshot count, which is the `-mtime +7` lesson
`postgresql_backup` already paid for: seven *snapshots* and seven *days* are the same number only
while nothing goes wrong.

## Verification

1. `systemctl is-active rest-server` reads `active`, and `ss -ltnp | grep 8000` shows the
   **Tailscale** address, not `0.0.0.0`. A wildcard bind here would be the platform binding rule
   broken on the one machine whose job is to survive the others.
2. From vm102: `restic -r rest:http://<tailscale-ip-offsite>:8000/vm102 snapshots` answers with an
   empty list rather than an error.
3. Append-only actually holds. From vm102, after the first snapshot exists:
   `restic forget --keep-last 1 --prune` has to fail. If it succeeds, `--append-only` is not in
   effect and the control does not exist - which is worth knowing now rather than after an
   incident.
4. From a node that is not vm102 or lxc250, the port does not answer at all.

## Failure modes

- **`restic init` refused from the homelab.** Expected; see step 6.
- **The volume is not mounted after a reboot and `rest-server` writes into the mountpoint on the
  root filesystem.** The `nofail` entry above allows the boot to continue, which is the same
  trade [KE-15](../../docs/platform/known-errors.md#ke-15) is about: it keeps the machine reachable
  and lets a mount failure go unnoticed. Check `findmnt /srv/restic` before trusting a run.
- **Tailscale not up when `rest-server` starts.** The unit orders after `tailscaled` and binds a
  fixed address, which is exactly the [KE-18](../../docs/platform/known-errors.md#ke-18) shape:
  ordering is not readiness. If it fails at boot, give it the same gate the fleet uses -
  `wait-for-tailscale-ip.sh` - rather than a restart loop.

## Rollback

Destroy the instance and the volume. Nothing on the homelab side depends on the VPS existing: the
`offsite_backup` role fails its own preflight against an unreachable repository and leaves every
local copy untouched.

**Abort criteria, since destroying the volume is irreversible:** do not destroy it while it holds
the only copy of anything. That is not the case during provisioning and becomes the case the moment
the first backup completes.
