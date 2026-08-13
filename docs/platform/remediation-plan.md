# Remediation Plan

Open platform work, ordered by **loss risk and dependency**, not by interest.

**This document holds ordering and nothing else.** The technical detail of every item lives in
[`known-errors.md`](known-errors.md), [`changelog.md`](changelog.md) and the runbooks, and is not
repeated here — a second copy would be the one that goes stale. What is *not* recorded anywhere
else is why these items must happen in this sequence, and that is what this file exists for.

No dates. Milestones are expressed as dependencies, so a slipped hardware delivery does not make
the document wrong. **Update it in the same commit as the work it describes.**

---

## The dependency chain

Four items unblock most of the rest. Everything else is ordinary backlog.

```
secrets escrow ──────► lxc250 inventory adoption ──────► control node is inside
(~/.vault_pass)         (monitoring + patching)           the system it manages
                                                                    │
                                                          Terraform state can
                                                          safely live there

aux-disk replacement ──► Proxmox host becomes an Ansible node
(needs hardware)                        │
                          ┌─────────────┼──────────────┬─────────────────┐
                    SMART attributes  homelab_schedule  hand-deployed units
                    that matter       role applied      folded into roles
```

The right-hand branch is the important one: **four separate technical-debt entries in `CLAUDE.md`
all name "the host must become an Ansible node" as their prerequisite**, and none of them says what
else is waiting on it. That is the single highest-leverage move on this list.

---

## Tier 1 — Irreversible loss, not blocked on anything

Cheap in hours, catastrophic if left. Nothing here waits on hardware.

| # | Item | What is lost |
|---|---|---|
| 1 | Escrow `~/.vault_pass`, `hosts.yml`, the Ansible SSH key into Vaultwarden; demote the GitHub key to a read-only deploy key | **Unrecoverable.** One copy, gitignored, on the boot SSD with the unresolved [KE-14](known-errors.md#ke-14) faults. Losing the vault password makes every vaulted secret undecryptable — there is no restore path. See [lxc250 § Open Items](../nodes/lxc250.md) |
| 2 | **Execute** `runbooks/database/pg-restore.md` and record the date | The runbook exists and is complete; what is missing is evidence it works. With `-mtime +7` retention, one bad dump plus a week of silence loses everything |
| 3 | Off-site copy of the critical subsets (Vaultwarden export, Nextcloud DB, Paperless documents) | All backups are local, on the same site. No protection against site loss or ransomware |

## Tier 2 — Blocked on hardware

| # | Item | Unblocks |
|---|---|---|
| 4 | aux-disk replacement ([KE-13](known-errors.md#ke-13)) | Lifts the standing hold on `docker-compose-update`; removes the last store with no off-site copy |
| 5 | [KE-14](known-errors.md#ke-14) physical verification — 12 V rail, cable reseat, HBA temperature, PSU age | **Not delivery-blocked.** Needs only host downtime, which the nightly RTC cycle already provides |
| 6 | Consider moving the boot SSD off the LSI SAS2008 to an onboard SATA port | Hypothesis-discriminating: if the KE-14 bursts stop it was the HBA path, if they persist it is power. Either way the SSD regains TRIM, which the HBA currently blocks |

## Tier 3 — Behind the host adoption

| # | Item | Note |
|---|---|---|
| 7 | Proxmox host becomes an Ansible node | **Trap:** `node_exporter_textfile_dir` must be set in `host_vars`, or the role silently drops the textfile collector — and with it both SMART and the thin-pool metrics |
| 8 | Extend the SMART collector to the attributes that matter | `smart_health_passed` reads PASSED for the disk with 7680 unreadable sectors. `Reported_Uncorrect`, `Current_Pending_Sector`, `Reallocated_Sector_Ct`, `Wear_Leveling_Count` are not exported and the `smart` rule group is empty |
| 9 | Fold the hand-deployed host units into roles | `node_exporter`, `wait-for-tailscale-ip.sh`, `lxc-fstrim`, `lvm-thin-metrics` — all lost on a rebuild |
| 10 | Apply the `homelab_schedule` role | Decide cron vs. timer explicitly; cron is defensible here because the job powers the host down |
| 11 | `is_mountpoint 1` on the `appdata_aux-disk` storage | KE-7 failure class; `mkdir 0` does not prevent it |

## Tier 4 — Ordinary backlog

lxc250 inventory adoption and its `preflight.yml` gate — which must **replace** that node's
hand-written `node_exporter` binding `*:9100`, not merely add one ([lxc250 § Open
Items](../nodes/lxc250.md#open-items-2026-07-28)) · the lxc250 sshd drop-in as the fifth
[KE-18](known-errors.md#ke-18) instance · `DATA_SOURCE_NAME` into Vault · delete the disabled
`tailscaled-userspace.service` file on lxc220 · pin journald `Storage=persistent` on vm100/vm102 ·
`pveproxy` drop-in onto the shared wait script · the missing `SystemdUnitFailed` coverage on
lxc200 **and lxc250** · clean up the ten orphaned `smart.prom.*` temp files in the host's textfile
directory (still present 2026-08-13; the collector leaks one per failed run) ·
[KE-5](known-errors.md#ke-5) Vaultwarden migration off CIFS.

---

## Deferred on purpose

- **Apache on lxc210 binding `*:80`/`*:443`, and vm100 sshd binding `0.0.0.0:22`.** Both are real
  binding-rule violations, and both need their own design decision — the lxc210 fix is plausibly
  "move Nextcloud behind `tailscale serve`", which would also retire [KE-16](known-errors.md#ke-16)
  entirely. That is a project, not a fix to bolt onto an unrelated pass.
- **Alertmanager routing and per-tier dashboards.** The alerts exist; only delivery is crude.
- **Molecule.** Out of scope for the current learning arc, per the roadmap.
- **KE-3, KE-11, KE-17.** Non-blocking, or no confirmed root cause to act on.
- **[KE-10](known-errors.md#ke-10) (Jellyfin CUDA loss).** Deferred, but note it is *active*, not
  historical — the watchdog restarted Jellyfin on 2026-08-07 and 2026-08-10. The workaround
  absorbs each occurrence silently, which is why it looks dormant.
