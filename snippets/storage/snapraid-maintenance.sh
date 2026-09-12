#!/usr/bin/env bash
set -euo pipefail

# Run snapraid sync or scrub and write Prometheus textfile metrics.
# Usage: snapraid-maintenance.sh sync|scrub|status
#
# Deployed to VM102 by the `snapraid_maintenance` Ansible role, which also installs
# snapraid-sync.timer and snapraid-scrub.timer:
#   ansible-playbook playbooks/snapraid-maintenance.yml --check --diff
#
# Do not schedule this from cron. The host is powered down overnight, so a cron
# entry at 23:00 is silently skipped on every night the shutdown lands first and is
# never retried. The timers use Persistent=true and catch up at the next boot.
#
# Prerequisite: the textfile collector directory, created fleet-wide by the
# `node_exporter` role (node_exporter_textfile_dir).
#
# Why `status` exists as a mode of its own, added 2026-09-11:
# the two metrics this script wrote until then recorded when a sync and a scrub
# last succeeded, and SnapRAIDScrubStale read the second one. Measured 2026-08-17,
# that rule was green while the oldest block in the array had not been verified for
# 123 days and 74% of the array had never been scrubbed at all. The rule was not
# wrong about what it measured; it measured that the job ran, not that the job
# reached anything - the same shape as smart_health_passed reporting PASSED for a
# disk with 7680 unreadable sectors. `snapraid status` already prints both numbers,
# so exporting them costs a parse rather than an array operation.

MODE="${1:-}"
TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"

if [[ "$MODE" != "sync" && "$MODE" != "scrub" && "$MODE" != "status" ]]; then
  echo "Usage: $0 sync|scrub|status" >&2
  exit 1
fi

if ! command -v snapraid &>/dev/null; then
  echo "ERROR: snapraid not found in PATH" >&2
  exit 1
fi

if [ ! -d "$TEXTFILE_DIR" ]; then
  echo "ERROR: textfile collector directory ${TEXTFILE_DIR} does not exist" >&2
  exit 1
fi

# Write one .prom file atomically. node_exporter reads *.prom only, so the staging
# file is invisible to it while being written, and keeping it in the same directory
# keeps the rename inside one filesystem.
#
# A fixed staging name rather than mktemp, deliberately. The retired SMART collector
# used mktemp without a cleanup trap and leaked one file per failed run: fourteen
# orphans dating back to 2025-12 were cleared on 2026-09-09. A fixed name cannot
# accumulate - a run that dies between write and rename leaves exactly one file,
# which the next run overwrites.
write_metrics() {
  local name="$1"
  local target="${TEXTFILE_DIR}/${name}.prom"
  umask 022
  cat > "${target}.new"
  mv "${target}.new" "${target}"
}

# Extract the first capture group of a POSIX ERE from stdin-held text, or print
# nothing. `grep -o` plus `tr -dc` rather than a PCRE: busybox-free Debian has GNU
# grep, but -P is a compile-time option and this script is not the place to find out
# it was omitted.
# Always exits 0. That is not cosmetic: this runs under `set -e`, and an
# assignment from a command substitution whose last command exits non-zero kills
# the script. Without the `|| true` the absence handling further down is
# unreachable code - which is exactly what happened on 2026-09-12, when the
# zero-sub-second pattern missed and the unit died at exit 1 before reaching the
# branch written to tolerate a missing value.
extract_number() {
  local text="$1" pattern="$2"
  { grep -oE "$pattern" <<<"$text" | head -1 | grep -oE '[0-9]+' | head -1; } || true
}

# Export coverage rather than recency. Called after a successful sync or scrub and
# by the `status` mode; a failure to parse leaves snapraid_status_parse_ok at 0
# instead of failing the run that called it, because a sync that worked must not be
# reported as failed by a reporting step.
write_status_metrics() {
  local out age unscrubbed zerosub parse_ok=1

  if ! out="$(snapraid status 2>&1)"; then
    echo "WARNING: snapraid status exited non-zero; coverage metrics not updated" >&2
    parse_ok=0
    out=""
  fi

  # "The oldest block was scrubbed 126 days ago, the median 80, the newest 12."
  age="$(extract_number "$out" 'oldest block was scrubbed [0-9]+ day')"
  # "The 74% of the array is not scrubbed." - snapraid omits the line entirely when
  # the array is fully scrubbed, so an absent match means 0, not unknown.
  unscrubbed="$(extract_number "$out" '[0-9]+% of the array is not scrubbed')"
  # "You have 63350 files with zero sub-second timestamp." - likewise absent when
  # there are none, in which case snapraid prints a "No file has ..." sentence.
  #
  # The article is optional in the pattern because the version on vm102 does not
  # print one, and the first draft of this script assumed it did. The wording was
  # written from memory rather than from the command's output, and it cost a
  # failed unit on the first scheduled run.
  zerosub="$(extract_number "$out" 'have [0-9]+ files with (a )?zero sub-second')"

  if [[ -z "$age" ]]; then
    # Only this one is genuinely unknown when absent: a never-scrubbed array prints
    # no age at all, and reporting 0 there would read as "scrubbed today".
    parse_ok=0
    age=""
  fi
  [[ -n "$unscrubbed" ]] || unscrubbed=0
  [[ -n "$zerosub" ]] || zerosub=0

  {
    echo "# HELP snapraid_status_parse_ok Whether the last snapraid status output could be read."
    echo "# TYPE snapraid_status_parse_ok gauge"
    echo "snapraid_status_parse_ok ${parse_ok}"
    echo "# HELP snapraid_status_last_run_timestamp Unix time of the last snapraid status read."
    echo "# TYPE snapraid_status_last_run_timestamp gauge"
    echo "snapraid_status_last_run_timestamp $(date +%s)"
    if [[ -n "$age" ]]; then
      echo "# HELP snapraid_scrub_oldest_block_age_days Age of the least recently verified block."
      echo "# TYPE snapraid_scrub_oldest_block_age_days gauge"
      echo "snapraid_scrub_oldest_block_age_days ${age}"
    fi
    # Both of these are emitted only when the output was recognisable at all.
    # Treating an absent line as zero is right when snapraid omits it because the
    # count is zero, and wrong when the whole output is something this script
    # cannot read - there "0% unscrubbed" would be a confident answer to a
    # question nobody managed to ask. The age above is the marker for which case
    # this is, since a recognisable status always carries it.
    if (( parse_ok == 1 )); then
      echo "# HELP snapraid_array_unscrubbed_ratio Fraction of the array no scrub has verified."
      echo "# TYPE snapraid_array_unscrubbed_ratio gauge"
      echo "snapraid_array_unscrubbed_ratio $(awk "BEGIN{printf \"%.4f\", ${unscrubbed}/100}")"
      echo "# HELP snapraid_zero_subsecond_files Files whose timestamp has no sub-second part."
      echo "# TYPE snapraid_zero_subsecond_files gauge"
      echo "snapraid_zero_subsecond_files ${zerosub}"
    fi
  } | write_metrics snapraid_status

  if (( parse_ok == 1 )); then
    echo "OK: coverage metrics written (oldest block ${age}d, ${unscrubbed}% unscrubbed, ${zerosub} zero-subsecond files)"
  fi
}

case "$MODE" in
  sync)
    # snapraid detects change by size and mtime. A file whose mtime has no
    # sub-second part is indistinguishable from another written in the same second,
    # which is why upstream ships `touch` to fill those in. 63322 files carried a
    # zero sub-second timestamp when this was measured on 2026-08-17. The command
    # writes metadata only, never file content, and is a no-op once converged.
    # Non-fatal on purpose: protecting the array tonight matters more than filling
    # in a timestamp, and `set -e` would otherwise let a touch failure skip the sync.
    snapraid touch || echo "WARNING: snapraid touch failed; continuing to sync" >&2
    snapraid sync
    echo "snapraid_sync_last_success_timestamp $(date +%s)" | write_metrics snapraid_sync
    echo "OK: snapraid sync completed at $(date)"
    write_status_metrics
    ;;
  scrub)
    snapraid scrub
    echo "snapraid_scrub_last_success_timestamp $(date +%s)" | write_metrics snapraid_scrub
    echo "OK: snapraid scrub completed at $(date)"
    write_status_metrics
    ;;
  status)
    write_status_metrics
    ;;
esac
