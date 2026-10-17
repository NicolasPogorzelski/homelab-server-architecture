# Runbook: Provision the off-site backup VPS

- **Use when:** building the off-site target, once
  ([remediation plan](../../docs/platform/remediation-plan.md#off-site-backup)); after it,
  [`backup/offsite-backup.md`](../backup/offsite-backup.md) takes over.
- **Duration:** about 1 hour.
- **Risk:** a REST port reachable from the internet; a repository password that is lost makes the
  repository unreadable; destroying the volume after the first backup destroys the only off-site
  copy.
- **Last exercised:** never

Target per [`offsite-backup-target.md`](../../docs/decisions/offsite-backup-target.md): a small VPS
running `rest-server` in append-only mode with `--private-repos`, written to by `restic` from vm102
and lxc250, one repository and one account each. Built by hand; Terraform adopts it later.

## Preconditions

- An account with a European provider offering a small hourly-billed instance and an attachable
  volume (Hetzner Cloud is the working assumption).
- An SSH key for the VPS, distinct from the Ansible key on lxc250.
- A DNS name decided, or none: the Tailscale address in the repository URL needs no public zone.

## Steps

Everything runs on the VPS as root unless stated otherwise.

1. Create the smallest instance and a volume (100 GB covers the C1 set plus history).
   Check: `ls /dev/disk/by-id/` lists the volume.
2. Base packages and SSH hardening before anything is stored.
   ```bash
   apt-get update && apt-get -y upgrade
   apt-get -y install ufw fail2ban rest-server restic apache2-utils
   sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
   sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
   systemctl restart ssh
   ```
   Check: `sshd -T | grep -E '^(passwordauthentication|permitrootlogin)'` prints `no` and
   `prohibit-password`; a new key-based session works before the old one closes.
3. Tailscale.
   ```bash
   curl -fsSL https://tailscale.com/install.sh | sh
   tailscale up --advertise-tags=tag:offsite --ssh=false
   tailscale ip -4
   ```
   In the admin console, grant vm102 and lxc250 access to `tag:offsite` on TCP 8000 and nothing
   else; mirror it in [`tailscale-acl.md`](../../docs/platform/tailscale-acl.md).
   Check: `tailscale status` shows the node with `tag:offsite`.
4. Firewall: SSH public, the REST port on the tailnet interface only.
   ```bash
   ufw default deny incoming
   ufw allow OpenSSH
   ufw allow in on tailscale0 to any port 8000 proto tcp
   ufw enable
   ```
   Check: `ufw status verbose` shows `8000/tcp on tailscale0 ALLOW IN` and no other 8000 rule.
5. Storage and service account.
   ```bash
   mkfs.ext4 /dev/disk/by-id/<volume>          # never a kernel letter
   mkdir -p /srv/restic
   echo '/dev/disk/by-id/<volume> /srv/restic ext4 defaults,nofail 0 2' >> /etc/fstab
   mount /srv/restic
   useradd --system --home /srv/restic --shell /usr/sbin/nologin restic
   chown -R restic:restic /srv/restic
   ```
   Check: `findmnt -no SOURCE,FSTYPE /srv/restic` shows the volume and `ext4`.
6. Accounts for the REST server.
   ```bash
   htpasswd -B -c /srv/restic/.htpasswd vm102
   htpasswd -B /srv/restic/.htpasswd lxc250
   chown restic:restic /srv/restic/.htpasswd && chmod 600 /srv/restic/.htpasswd
   ```
   Check: the file has two lines.
7. The append-only unit, `/etc/systemd/system/rest-server.service`:
   ```ini
   [Unit]
   Description=restic REST server, append-only
   After=network-online.target tailscaled.service
   Wants=network-online.target

   [Service]
   User=restic
   # --append-only: clients can create and read snapshots, never remove them.
   # --private-repos: each account is confined to its own path.
   # Tailscale address only: the port is never public.
   ExecStart=/usr/bin/rest-server --path /srv/restic --append-only --private-repos \
     --htpasswd-file /srv/restic/.htpasswd --listen <tailscale-ip-offsite>:8000
   Restart=on-failure

   [Install]
   WantedBy=multi-user.target
   ```
   ```bash
   systemctl daemon-reload && systemctl enable --now rest-server
   ```
   Check: `ss -ltnp | grep 8000` shows `<tailscale-ip-offsite>:8000`, not `0.0.0.0`.
8. Initialise both repositories on the server; an append-only account cannot write the config
   object `restic init` creates.
   ```bash
   sudo -u restic restic -r /srv/restic/vm102  init
   sudo -u restic restic -r /srv/restic/lxc250 init
   ```
   Record both passwords on paper with the Ansible vault password escrow.
   Check: `sudo -u restic restic -r /srv/restic/vm102 snapshots` prompts for the password and
   lists none.
9. Server-side retention, since clients cannot prune: a timer running as `restic` with direct
   filesystem access, per repository:
   ```bash
   sudo -u restic restic -r /srv/restic/vm102 forget \
     --keep-daily 7 --keep-weekly 5 --keep-monthly 12 --prune
   ```
   Check: `systemctl list-timers` shows the retention timer with a `NEXT` time.

## Verification

1. `systemctl is-active rest-server` is `active`; the listener is the Tailscale address only.
2. From vm102: `restic -r rest:http://vm102:<password>@<tailscale-ip-offsite>:8000/vm102/ snapshots`
   returns an empty list, not an error.
3. After the first snapshot, from vm102: `restic forget --keep-last 1 --prune` fails. If it
   succeeds, `--append-only` is not in effect.
4. From a node other than vm102 and lxc250, port 8000 does not answer; from the internet neither.

## Failure modes

| Symptom | Cause | Action |
|---|---|---|
| `restic init` refused from the homelab | Append-only account | Expected; step 8 runs on the server |
| `rest-server` writes into `/srv/restic` on the root filesystem | Volume not mounted at boot (`nofail`) | `findmnt /srv/restic` before trusting a run ([KE-15](../../docs/platform/known-errors.md#ke-15)) |
| `rest-server` fails at boot with `cannot assign requested address` | Started before `tailscaled` had its address ([KE-18](../../docs/platform/known-errors.md#ke-18)) | Add an `ExecStartPre=` gate like `snippets/scripts/wait-for-tailscale-ip.sh`, not a restart loop |
| Clients time out on 8000 | No `ufw` rule on `tailscale0`, or no ACL grant | Step 4; step 3 grant |

## Rollback

Destroy the instance and the volume. Nothing in the homelab depends on the VPS while the
`offsite_backup` role is not deployed. Once the first backup has completed, the volume holds the
only off-site copy: do not destroy it without a replacement target.

## Background

Retention runs in time classes, not a snapshot count, so a run of failed days does not shorten the
history. Residual risk accepted in the decision: root on the VPS can still delete the repositories.
