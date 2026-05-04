# Claude Code Hooks Reference

`hooks-reference.json` is a sanitized copy of `.claude/settings.local.json`.
The real file is gitignored. Use this as a reference when setting up a new machine.

Replace `<repo-path>` with the absolute path to this repository before use,
or run `install.sh` from the `dotfiles` repo which does this automatically.

## Hooks

**SessionStart**
Injects the current branch name and last 5 commits into Claude's context at
session start. Eliminates the need to manually brief Claude on where work left off.

**PreToolUse (`git commit *`)**
Runs two checks before every commit:
1. Blocks direct commits on `main` — a branch must be used
2. Runs `validate-repo.sh` and blocks the commit if any check fails

**Stop**
Reminds Claude to update `~/git/devops-til/` at the end of every session.
New concepts go into new `.md` files; the README index must be updated and pushed.
