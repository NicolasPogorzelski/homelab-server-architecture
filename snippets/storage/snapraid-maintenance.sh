#!/usr/bin/env bash
set -euo pipefail

# Run snapraid sync or scrub and write Prometheus textfile metrics.
# Usage: snapraid-maintenance.sh sync|scrub|status
#
# Deployed to VM102 by the `snapraid_maintenance` Ansible role, which also installs
# snapraid-sync.timer and snapraid-scrub.timer:
#   ansible-playbook playbooks/snapraid-maintenance.yml --check --diff
#
# Not from cron: the host powers down nightly and cron never retries a skipped run;
# the timers use Persistent=true. The textfile directory comes from the
# `node_exporter` role.
#
# `status` exports coverage (oldest block age, unscrubbed share), not just recency:
# a last-success timestamp proves the job ran, not that it reached the whole array.
# Sync and scrub record their wall-clock duration, because a scrub must finish
# before the nightly shutdown (`snapraid_maintenance` and `homelab_schedule` defaults).

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

# Write one .prom file atomically: node_exporter reads *.prom only, and the same
# directory keeps the rename inside one filesystem. A fixed staging name rather than
# mktemp, so a run that dies before the rename leaves one file the next run overwrites.
write_metrics() {
  local name="$1"
  local target="${TEXTFILE_DIR}/${name}.prom"
  umask 022
  cat > "${target}.new"
  mv "${target}.new" "${target}"
}

# Print the first number in the first match of a POSIX ERE, or nothing. ERE, not
# PCRE: grep -P is a compile-time option.
# Always exits 0: under `set -e` a failing assignment would kill the script before
# the absence handling below is reached.
extract_number() {
  local text="$1" pattern="$2"
  { grep -oE "$pattern" <<<"$text" | head -1 | grep -oE '[0-9]+' | head -1; } || true
}

# Export coverage rather than recency. A parse failure sets snapraid_status_parse_ok
# to 0 instead of failing a sync or scrub that worked.
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
  # The article is optional: the snapraid version on vm102 prints none.
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
    # Emitted only when the output was recognisable (the age line is the marker):
    # absent-means-zero is right for an omitted line, wrong for unreadable output.
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
    # snapraid detects change by size and mtime; `touch` fills in missing sub-second
    # mtimes (metadata only). Non-fatal: a touch failure must not skip the sync.
    snapraid touch || echo "WARNING: snapraid touch failed; continuing to sync" >&2
    started=$(date +%s)
    snapraid sync
    finished=$(date +%s)
    {
      echo "# HELP snapraid_sync_last_success_timestamp Unix time the last sync finished successfully."
      echo "# TYPE snapraid_sync_last_success_timestamp gauge"
      echo "snapraid_sync_last_success_timestamp ${finished}"
      echo "# HELP snapraid_sync_duration_seconds Wall-clock seconds of the last successful sync."
      echo "# TYPE snapraid_sync_duration_seconds gauge"
      echo "snapraid_sync_duration_seconds $((finished - started))"
    } | write_metrics snapraid_sync
    echo "OK: snapraid sync completed at $(date) in $((finished - started))s"
    write_status_metrics
    ;;
  scrub)
    # -p is the share of the array one run verifies. The unit sets it from the
    # role defaults; run by hand, the script uses snapraid's own default of 8.
    percent="${SNAPRAID_SCRUB_PERCENT:-8}"
    started=$(date +%s)
    snapraid scrub -p "$percent"
    finished=$(date +%s)
    {
      echo "# HELP snapraid_scrub_last_success_timestamp Unix time the last scrub finished successfully."
      echo "# TYPE snapraid_scrub_last_success_timestamp gauge"
      echo "snapraid_scrub_last_success_timestamp ${finished}"
      echo "# HELP snapraid_scrub_duration_seconds Wall-clock seconds of the last successful scrub."
      echo "# TYPE snapraid_scrub_duration_seconds gauge"
      echo "snapraid_scrub_duration_seconds $((finished - started))"
    } | write_metrics snapraid_scrub
    echo "OK: snapraid scrub of ${percent}% completed at $(date) in $((finished - started))s"
    write_status_metrics
    ;;
  status)
    write_status_metrics
    ;;
esac
