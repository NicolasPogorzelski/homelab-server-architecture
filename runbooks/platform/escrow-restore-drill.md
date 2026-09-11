# Runbook: annual escrow restore drill

## Problem

Three artefacts exist in one copy each on lxc250, and lxc250 lives on the disk of
[KE-14](../../docs/platform/known-errors.md#ke-14):

- `~/.vault_pass`, the Ansible Vault password.
- `ansible/inventory/hosts.yml`, the real inventory. Gitignored, so no commit holds it.
- The Ansible SSH key that reaches every node.

They were escrowed on 2026-08-20 - held in an external password manager operated by a third party,
with the most important of them written on paper and kept outside the flat. That closed the
irreversible-loss risk in Tier 1 item 1 of the [remediation plan](../../docs/platform/remediation-plan.md).

It did not close the other half. An escrow that has never been restored from is the same fiction as
an untested backup, and this repository has already paid once for the difference: the PostgreSQL
dumps were believed good for months on the strength of the job exiting 0, and the first actual
restore was run on 2026-08-13.

There is a second, sharper reason to rehearse this one. The item names three artefacts and only one
of them is a password. A password manager holding "all the passwords" does not necessarily hold a
120-byte SSH private key or a YAML file, and the day to discover which is not the day lxc250 is
gone.

## Preconditions

- Once a year. Pick a fixed month and keep it; the date matters less than the fact that a date
  exists. The last recorded execution is at the bottom of this runbook.
- A workstation other than lxc250. The whole point is to prove the material can be recovered
  without the machine it normally lives on.
- Physical retrieval of the paper copy. Not a photograph of it, not a memory of what it says.
- Roughly thirty minutes, and no live change planned for the same session - this drill ends with
  secret material on a second machine, and that material gets destroyed before anything else
  starts.

## Procedure

### 1. Retrieve, do not recall

Fetch the paper copy from where it is kept, and open the password manager entry. Write down, before
comparing them, what you expect each to contain. An expectation recorded after looking is not a
test.

### 2. Establish what is actually held

For each of the three artefacts, answer yes or no from what is in front of you:

| Artefact | Held on paper? | Held in the manager? | Complete? |
|---|---|---|---|
| Vault password | | | |
| `hosts.yml` | | | |
| Ansible SSH private key | | | |

"Complete" is the column that catches the likely failure. A key stored without its final newline,
or an inventory stored as a screenshot, is a record of the artefact rather than the artefact.

### 3. Exercise the vault password

On the second workstation, against a checkout of this repository:

```bash
# Any vaulted file will do; this one exists on purpose.
ansible-vault view ansible/inventory/group_vars/all/vault.yml
```

Enter the password from the paper copy by hand, not from the manager, and not from a clipboard. The
paper is the copy least likely to be exercised and therefore the one most likely to be wrong.

Expected: the decrypted YAML. A `Decryption failed` means the escrowed password is not the live one,
which is the finding the drill exists for.

### 4. Exercise the SSH key

Write the escrowed key to a temporary file with mode 0600 and use it once, read-only:

```bash
install -m 0600 /dev/null /tmp/escrow-test-key
# paste the escrowed key into it, then:
ssh -i /tmp/escrow-test-key -o IdentitiesOnly=yes ansible@<a-node> 'hostname; uptime -s'
```

`IdentitiesOnly=yes` matters: without it the agent offers every key it holds and a working
connection proves nothing about the one being tested.

### 5. Exercise the inventory

```bash
ansible-inventory -i <path-to-escrowed-hosts.yml> --list >/dev/null && echo "parses"
ansible-inventory -i <path-to-escrowed-hosts.yml> --graph
```

Compare the group membership against
[`ansible.md`](../../docs/platform/ansible.md#inventory). An inventory that parses but is two nodes
out of date is worth knowing about while there is still a live copy to compare it with.

### 6. Destroy the working copies

```bash
shred -u /tmp/escrow-test-key
# and any file the inventory or vault password was pasted into
```

Then return the paper to where it came from, and confirm it is back before closing the session.

## Verification

The drill has passed when all four are true and the date below is updated in the same commit:

1. All three artefacts were retrievable from at least one escrow, and the table in step 2 has no
   empty cell.
2. `ansible-vault view` decrypted using the paper copy of the password.
3. The escrowed SSH key authenticated to a node, with `IdentitiesOnly=yes`.
4. The escrowed inventory parsed and its groups matched the documented set.

Record it the way [`pg-restore.md`](../database/pg-restore.md) records its restores: the date, what
was exercised, and what was found. A pass with no findings still gets written down, because the
value of the record is the interval between entries.

## Failure

- **The paper password does not decrypt.** The vault password was rotated and the escrow was not.
  Re-escrow immediately from the live copy on lxc250, both to paper and to the manager, and record
  the rotation date. This is recoverable only while lxc250 exists, which is the whole point.
- **An artefact is missing from both escrows.** Add it in the same session. Do not note it as a
  follow-up; the follow-up is what created the gap.
- **The SSH key authenticates but the inventory is stale.** Refresh the escrowed copy. A stale
  inventory is a slower failure than a missing one and is easy to talk yourself out of fixing.
- **You cannot retrieve the paper copy at all.** That is the most serious outcome available from
  this drill and it is better discovered here than during a rebuild. Re-establish the off-site copy
  before doing anything else in the session.

## Rollback

Nothing here changes the platform. The only state created is the temporary files in step 4 and 5,
and destroying them is step 6 rather than an afterthought.

If the drill ends early for any reason, destroy the working copies anyway. A key left in `/tmp`
on a workstation is a worse outcome than an unfinished drill.

## Execution log

| Date | Executed by | Result |
|---|---|---|
| - | - | Not yet executed. The escrow was created on 2026-08-20 and has not been restored from |

## Related

- [Remediation plan, Tier 1 item 1](../../docs/platform/remediation-plan.md)
- [LXC250 rebuild](lxc250-rebuild.md) - the procedure this material is needed for
- [PostgreSQL restore](../database/pg-restore.md) - the recording convention this follows
- [Ansible platform doc](../../docs/platform/ansible.md)
