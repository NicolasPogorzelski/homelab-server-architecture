#!/usr/bin/env python3
"""Weekly check whether upstream fixes the platform waits for have been released.

Deployed by the upstream_watch role; edit this file, never the node copy.

A mitigation that waits for an upstream fix is recorded in known-errors.md with
the pull request that fixes it. This script asks GitHub, per watched item,
whether that pull request is merged and whether the latest release contains the
merge commit, and exports both as metrics. UpstreamFixReleased fires once a
release carries the fix and names the mitigation to revert.

Items come from /etc/upstream-watch.conf, one per line: name|owner/repo|pr|known-error.
"""
import json
import os
import sys
import tempfile
import time
import urllib.error
import urllib.request

CONF = "/etc/upstream-watch.conf"
TEXTFILE_DIR = sys.argv[1] if len(sys.argv) > 1 else "/var/lib/node_exporter/textfile_collector"
PROM_FILE = os.path.join(TEXTFILE_DIR, "upstream-watch.prom")


def api(path):
    req = urllib.request.Request(f"https://api.github.com{path}",
                                 headers={"Accept": "application/vnd.github+json", "User-Agent": "upstream-watch"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def check(repo, pr):
    """Returns (merged, released, release_tag)."""
    p = api(f"/repos/{repo}/pulls/{pr}")
    if not p.get("merged"):
        return 0, 0, ""
    tag = api(f"/repos/{repo}/releases/latest")["tag_name"]
    # "behind" or "identical": the merge commit is an ancestor of the release tag.
    status = api(f"/repos/{repo}/compare/{tag}...{p['merge_commit_sha']}")["status"]
    return 1, int(status in ("behind", "identical")), tag


lines, ok = [], True
for raw in open(CONF):
    raw = raw.strip()
    if not raw or raw.startswith("#"):
        continue
    name, repo, pr, ke = raw.split("|")
    try:
        merged, released, tag = check(repo, pr)
    except (urllib.error.URLError, KeyError, ValueError) as e:
        print(f"ERROR {name}: {e}", file=sys.stderr)
        ok = False
        continue
    labels = f'item="{name}",repo="{repo}",pr="{pr}",known_error="{ke}"'
    lines.append(f"upstream_watch_fix_merged{{{labels}}} {merged}")
    lines.append(f'upstream_watch_fix_released{{{labels},release="{tag}"}} {released}')
    print(f"{name}: merged={merged} released={released} {tag}")

lines.append(f"upstream_watch_last_run_timestamp_seconds {int(time.time())}")
lines.append(f"upstream_watch_last_run_success {int(ok)}")
os.makedirs(TEXTFILE_DIR, exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=TEXTFILE_DIR, prefix=".upstream-watch.")
with os.fdopen(fd, "w") as f:
    f.write("\n".join(lines) + "\n")
os.chmod(tmp, 0o644)
os.replace(tmp, PROM_FILE)
sys.exit(0 if ok else 1)
