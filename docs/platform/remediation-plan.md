# Remediation Plan

Open platform work, ordered by **loss risk and dependency**, not by interest.

**This document holds ordering and nothing else.** The technical detail of every item lives in
[`known-errors.md`](known-errors.md), [`changelog.md`](changelog.md) and the runbooks, and is not
repeated here — a second copy would be the one that goes stale. What is *not* recorded anywhere
else is why these items must happen in this sequence, and that is what this file exists for.

No dates. Milestones are expressed as dependencies, so a slipped hardware delivery does not make
the document wrong. **Update it in the same commit as the work it describes.**

For the same items read as security controls rather than as work — which standard control each one
implements, and which are enforced rather than merely practised — see
[`security-controls.md`](security-controls.md). It does not duplicate this ordering; it explains
what is at stake in each item's language rather than in this repository's.

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
| 1 | Escrow `~/.vault_pass`, `hosts.yml`, the Ansible SSH key **off-site** — sealed on paper outside the flat, plus a password manager somebody else operates. Demote the GitHub key to a read-only deploy key | **Unrecoverable.** One copy, gitignored, on the boot SSD with the unresolved [KE-14](known-errors.md#ke-14) faults. Losing the vault password makes every vaulted secret undecryptable — there is no restore path. See [lxc250 § Open Items](../nodes/lxc250.md). **Target corrected 2026-08-14 — this line used to say "into Vaultwarden", and that was wrong:** see the note below |
| 2 | ~~Execute `runbooks/database/pg-restore.md`, record the date, put it on a cadence~~ **Done 2026-08-13.** ~~Remaining: make the backup script verify its own output (`gzip -t` + completion marker) at write time~~ **Done 2026-08-14** — plus write-to-`.partial`-then-rename, so an unverified dump never appears under the real name, and verification ordered before retention deletion | Closed. A dump that cannot be read now fails the run that wrote it and raises `SystemdUnitFailed`, instead of surviving up to 31 days until the monthly restore test — by which point the 7-day retention has deleted every healthy predecessor. Note the write-time checks prove the stream is complete, not that it is durable on vm102: the read-back is served from the CIFS page cache. Durability remains the restore test's job |
| 3 | Off-site copy of the **C1 datasets** defined in [`data-classification.md`](data-classification.md) | All backups are local, on the same site. No protection against site loss or ransomware. **Scope defined 2026-08-15 — and this line's earlier wording was wrong.** It read "off-site copy of the critical subsets (Vaultwarden export, Nextcloud DB, Paperless documents)", which presumes local copies exist that merely need duplicating elsewhere. Two of them do not exist: the Nextcloud MariaDB has **no backup at all**, and Vaultwarden has no consistent export. Those must be created first — an off-site copy of nothing is nothing. **Status 2026-08-15:** the MariaDB half is built (`mariadb_backup` role + [runbook](../../runbooks/database/mariadb-backup.md)) and blocked only on provisioning the backup share; the Vaultwarden export is still open |

**Why item 1 no longer says "into Vaultwarden" (decided 2026-08-14).** Vaultwarden's persistent data
lives on `mp0: /mnt/smb/vaultwarden`, i.e. on vm102's MergerFS pool — so against the *predicted*
failure, the boot SSD dying, it genuinely would have been a second failure domain. But that is the
narrow reading. Against **site loss, theft, fire, or ransomware spreading over the SMB mounts** it
is worth nothing: same site, same power, same network. An escrow whose whole purpose is the
catastrophic case must not share a building with the original.

The corrected target is deliberately **not a server**: sealed on paper, kept outside the flat, plus
a copy in a password manager somebody else operates. The vault password is roughly 30 bytes of
static text that changes approximately never — a running system is the wrong medium for it, and
every additional machine is operational surface this fleet has already shown it does not
consistently supervise. A self-hosted VPS was considered and rejected **for this purpose**: it
answers "where does the secret live" with another system that itself needs credentials, which only
moves the root-of-trust question one hop and adds a hop that can fail. It becomes the right answer
once it carries item 3 (off-site backup target) and Terraform state as well — three purposes, not
one.

**And the same discipline as the dumps applies:** an escrow that has never been restored from is
the same fiction as an untested backup. Once a year, retrieve the paper copy and run
`ansible-vault view` against a vaulted file. Record the date, exactly as
[`pg-restore.md`](../../runbooks/database/pg-restore.md) does.

## Tier 2 — Blocked on hardware

| # | Item | Unblocks |
|---|---|---|
| 4 | aux-disk replacement ([KE-13](known-errors.md#ke-13)) — **including erasure of the removed disk before it leaves the flat** | Lifts the standing hold on `docker-compose-update`; removes the last store with no off-site copy. The disposal half is not optional and has no owner yet: the disk carries C1 application data, and with 7680 unreadable sectors a software overwrite cannot be assumed to have reached every block, so the honest options are degaussing or physical destruction. This is the only Annex A control on the list with a deadline set by hardware delivery rather than by choice (A.7.14) |
| 5 | [KE-14](known-errors.md#ke-14) physical verification — 12 V rail, cable reseat, HBA temperature, PSU age | **Not delivery-blocked.** Needs only host downtime, which the nightly RTC cycle already provides |
| 6 | Consider moving the boot SSD off the LSI SAS2008 to an onboard SATA port | Hypothesis-discriminating: if the KE-14 bursts stop it was the HBA path, if they persist it is power. Either way the SSD regains TRIM, which the HBA currently blocks |

## Tier 3 — Behind the host adoption

| # | Item | Note |
|---|---|---|
| 7 | Proxmox host becomes an Ansible node | **The trap listed here is obsolete, corrected 2026-08-15.** It read "`node_exporter_textfile_dir` must be set in `host_vars`, or the role silently drops the textfile collector". The default became fleet-wide on 2026-07-10 (`c134959`), and the host's hand-written unit uses the identical path — verified, so adoption needs no override. Left visible rather than deleted: a stale warning is its own hazard, because it deters exactly the work it was written to protect |
| 8 | Extend the SMART collector to the attributes that matter | `smart_health_passed` reads PASSED for the disk with 7680 unreadable sectors. `Reported_Uncorrect`, `Current_Pending_Sector`, `Reallocated_Sector_Ct`, `Wear_Leveling_Count` are not exported and the `smart` rule group is empty |
| 9 | Fold the hand-deployed host units into roles | `node_exporter`, `wait-for-tailscale-ip.sh`, `lxc-fstrim`, `lvm-thin-metrics` — all lost on a rebuild |
| 10 | Apply the `homelab_schedule` role | Decide cron vs. timer explicitly; cron is defensible here because the job powers the host down |
| 11 | `is_mountpoint 1` on the `appdata_aux-disk` storage | KE-7 failure class; `mkdir 0` does not prevent it |

## Tier 4 — Ordinary backlog

**External heartbeat (`Watchdog` alert → off-site receiver), added 2026-08-14.** The measurement
behind it is in the [changelog entry for 2026-08-14](changelog.md): `PostgreSQLBackupStale` could
not see three backup-free days, because Prometheus runs on the host that was off. That is
structural, not a threshold to retune — **an observer sharing a failure domain with the observed
cannot report its total failure.** The standard fix is the `Watchdog` pattern that
`kube-prometheus` ships by default: an alert whose expression is simply `vector(1)`, firing
permanently on purpose and routed outward. If the external receiver stops seeing it, the whole
alerting chain is down. Cost here is one rule plus one Alertmanager route; the receiver must be a
service somebody else operates (a free heartbeat SaaS), because a self-hosted one needs a watcher
of its own. Note the fleet already builds absence-alerts twice — `LvmThinMetricsStale` and
`PostgreSQLRestoreTestStale` — this extends the same idea to the alerting chain itself.


**Physical and environmental controls are undocumented (added 2026-08-15).** The whole A.7 family —
who has physical access to the machine, whether the disks are encrypted at rest, whether there is an
uninterruptible supply — has never been written down. It surfaces here because it stopped being
abstract: the leading hypothesis for [KE-14](known-errors.md#ke-14) is a sagging 12 V rail, i.e. an
open incident whose suspected cause is exactly the control nobody documented. Cheap to close on
paper, and the paper is what makes the KE-14 verification a planned step instead of a recurring
intention.

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
