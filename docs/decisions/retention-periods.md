# Retention Periods for Data Kept Without One

## Status
Proposed 2026-11-18. Supersedes / superseded by: -.

## Context
[`data-classification.md`](../platform/data-classification.md#retention-and-deletion) lists the
periods in force. Backups, dumps, monitoring history and the Jellyfin activity log have one. System
journals are bounded by size only, and documents, Nextcloud files, Talk messages and the media
services' histories are kept until a person deletes them. Annex A.8.10 asks that information be
deleted when it is no longer required.

The data without a period splits into three kinds:

- logs that hold addresses, account names and commands, kept for incident analysis;
- the owner's own documents and files, whose need only the owner can judge;
- the external user's account and history in Jellyfin, Audiobookshelf and Nextcloud Talk, whose
  purpose ends when that user's access ends.

## Options
- **Keep everything until deleted by hand.** No work, but logs grow to whatever the size cap holds,
  and an ended access leaves the external user's data behind.
- **One period for all data.** Simple, but a period short enough for logs deletes documents the
  owner still needs, and one long enough for documents keeps logs for years.
- **A period per kind of data, with deletion tied to the end of a purpose.**

## Decision
- System journals: 90 days, through `MaxRetentionSec=90day` in the `journald` drop-in, beside the
  size cap that stays as a ceiling. The monitoring history keeps its 30 days.
- The owner's documents and files: no fixed period. Paperless documents and Nextcloud files are
  reviewed once a year, and what is no longer needed is deleted; Nextcloud's trash and versions
  keep their `auto` setting.
- The external user's data: deleted within 30 days after that user's access ends, in all three
  services, together with the removal of the machine shares and of
  [Rule 13](../platform/tailscale-acl.md#rule-13---external-user-through-machine-sharing).
  Talk conversations with the owner go with the account.
- Media leaving the site: the disposal method is decided per device before it leaves, as the
  aux-disk item in the [remediation plan](../platform/remediation-plan.md) does.

## Consequences
- Logs older than 90 days are gone; an incident found later than that has no journal to read. The
  guest backups do not extend this, because they keep seven days.
- The yearly document review is a task for a person; no timer or alert enforces it.
- Ending the external user's access becomes a procedure with three services and the tailnet policy;
  it belongs in a runbook before it is needed.
- Applying the journal period is one variable in the `journald` role and a run of its playbook.
