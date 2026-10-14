## What and why

<!-- One paragraph: what changes on the platform or in the repository, and why. -->

## Checklist

- [ ] Each changed fact is changed in its owner file (Fact owners in `docs/CONVENTIONS.md`) and nowhere else
- [ ] Remediation plan: item closed (row removed) or new item added with rank and next step
- [ ] Known errors: status line updated for any entry this touches
- [ ] Runbooks: `Last exercised` updated if a runbook was run
- [ ] `./scripts/validate-repo.sh` passes locally; Ansible changes were run with `--check --diff` first

## Verification

<!-- Commands and output that show the change works: the check run, the metric, the probe. -->
