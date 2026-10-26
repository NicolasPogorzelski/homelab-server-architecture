# Runbook: Escrow restore drill

- **Use when:** yearly, in a fixed month; first run open
  ([remediation plan](../../docs/platform/remediation-plan.md#escrow-restore-drill)); before an
  [lxc250 rebuild](lxc250-rebuild.md).
- **Duration:** about 30 minutes.
- **Risk:** secret material on a second machine until step 6; nothing on the platform changes.
- **Last exercised:** never

Three artefacts exist on lxc250 only, which lives on the boot SSD
([KE-14](../../docs/platform/known-errors.md#ke-14)):

- `~/.vault_pass`, the Ansible Vault password (`vault_password_file` in `ansible/ansible.cfg`).
- `ansible/inventory/hosts.yml`, the real inventory, gitignored.
- The Ansible SSH key, which opens user `ansible` on the guests and root on the hypervisor.

They are escrowed in a password manager operated by a third party, with a paper
copy off site. The drill proves the escrow holds all three, complete, and that they work.

## Preconditions

- A workstation other than lxc250, with a checkout of this repository and Ansible installed.
- The paper copy, retrieved in person; a photograph does not count.
- No live change planned for the same session.

## Steps

1. Before opening either escrow, write down what each is expected to contain.
   Check: the expectation is on paper before step 2.
2. Record what is held:

   | Artefact | On paper | In the manager | Complete |
   |---|---|---|---|
   | Vault password | | | |
   | `hosts.yml` | | | |
   | Ansible SSH private key | | | |

   Check: no empty cell. A key without its final newline or an inventory stored as a screenshot is
   not complete.
3. Vault password, typed by hand from the paper copy (not the manager, not a clipboard):
   ```bash
   ansible-vault view ansible/inventory/group_vars/all/vault.yml
   ```
   Check: decrypted YAML. `Decryption failed` means the escrowed password is not the live one.
4. SSH key, once, read-only:
   ```bash
   install -m 0600 /dev/null /tmp/escrow-test-key
   # paste the escrowed key into it
   ssh -i /tmp/escrow-test-key -o IdentitiesOnly=yes ansible@<a-node> 'hostname; uptime -s'
   ```
   Check: hostname and boot time print. `IdentitiesOnly=yes` keeps the agent from offering other
   keys.
5. Inventory:
   ```bash
   ansible-inventory -i <escrowed-hosts.yml> --list >/dev/null && echo parses
   ansible-inventory -i <escrowed-hosts.yml> --graph
   ```
   Check: `parses`; groups and nodes match [`ansible.md`](../../docs/platform/ansible.md#inventory)
   and `ansible/inventory/hosts.yml.example`.
6. Destroy the working copies and return the paper.
   ```bash
   shred -u /tmp/escrow-test-key <every file the inventory or password was pasted into>
   ```
   Check: `ls /tmp/escrow-test-key` fails; the paper is back in place.

## Verification

The drill passes when all hold, recorded in the execution log and the header in the same commit:

1. All three artefacts retrievable from at least one escrow; the table has no empty cell.
2. `ansible-vault view` decrypted with the paper copy.
3. The escrowed key authenticated with `IdentitiesOnly=yes`.
4. The escrowed inventory parsed and its groups match the documented set.

## Failure modes

| Symptom | Cause | Action |
|---|---|---|
| Paper password does not decrypt | Vault password rotated, escrow not | Re-escrow from lxc250 to paper and manager now; record the rotation date |
| An artefact missing from both escrows | Never escrowed | Add it in the same session |
| Key authenticates, inventory stale | Inventory changed since escrow | Refresh the escrowed copy |
| Paper copy cannot be retrieved | Off-site copy lost | Re-establish it before anything else |

Each fix is possible only while lxc250 still holds the live copies.

## Rollback

Nothing on the platform changes. If the drill stops early, run step 6 anyway.

## Execution log

| Date | Result | Findings |
|---|---|---|
| - | Not yet executed | - |

## Background

Two of the three artefacts are files (`hosts.yml` and the SSH key), and a password manager may not
return a private key or a YAML file intact. Records follow the convention of
[`pg-restore.md`](../database/pg-restore.md): date, what was exercised, what was found, including a
pass with no findings.
