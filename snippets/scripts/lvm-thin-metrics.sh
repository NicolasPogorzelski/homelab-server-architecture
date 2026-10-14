#!/usr/bin/env bash
# Export LVM thin-pool utilisation to the node_exporter textfile collector.
#
# A thin pool is a block-layer object with no filesystem, so node_filesystem_* cannot
# observe it. Thin-pool overflow is the KE-7 failure.
#
# lvm_vg_free_bytes is exported alongside because `lvextend` needs unallocated extents in
# the VG; when there are none, runbooks/platform/lvm-thin-pool-full.md lists the options.
set -euo pipefail

OUTDIR="/var/lib/node_exporter/textfile_collector"
OUTFILE="${OUTDIR}/lvm-thin.prom"
mkdir -p "${OUTDIR}"

# node_exporter must be able to read the file; it reads *.prom only, so the temp file below
# is invisible to it while being written.
umask 022

# Staged in the *same* directory as the target: `mv` is only atomic within one filesystem.
#
# A fixed name rather than mktemp: an EXIT trap does not run on SIGKILL or power loss, and
# this host powers down on a schedule. A run that dies between write and rename leaves
# exactly one file, which the next run truncates.
TMPFILE="${OUTDIR}/lvm-thin.prom.staged"

scrape_success=1

# --units b --nosuffix gives plain bytes; percentages come back as strings like "92.55".
# An empty data_percent means the LV is not a thin pool, so those rows are skipped below.
lvs_json="$(
  lvs --reportformat json --units b --nosuffix \
      -o vg_name,lv_name,lv_size,data_percent,metadata_percent 2>/dev/null
)" || scrape_success=0

vgs_json="$(vgs --reportformat json --units b --nosuffix -o vg_name,vg_free 2>/dev/null)" \
  || scrape_success=0

{
  echo "# HELP lvm_thin_pool_data_percent Percentage of the thin pool's data space allocated."
  echo "# TYPE lvm_thin_pool_data_percent gauge"
  echo "# HELP lvm_thin_pool_metadata_percent Percentage of the thin pool's metadata space used."
  echo "# TYPE lvm_thin_pool_metadata_percent gauge"
  echo "# HELP lvm_thin_pool_size_bytes Size of the thin pool in bytes."
  echo "# TYPE lvm_thin_pool_size_bytes gauge"
  echo "# HELP lvm_vg_free_bytes Unallocated space in the volume group, i.e. room to lvextend."
  echo "# TYPE lvm_vg_free_bytes gauge"
  echo "# HELP lvm_thin_metrics_scrape_success Whether this collector's lvs/vgs calls succeeded."
  echo "# TYPE lvm_thin_metrics_scrape_success gauge"
} > "${TMPFILE}"

if (( scrape_success == 1 )); then
  # Filter on metadata_percent: thin *volumes* also report data_percent but no
  # metadata_percent, and a metric line with no value makes node_exporter discard the whole
  # file. Only a thin *pool* carries metadata_percent.
  jq -r '
    .report[0].lv[]
    | select(.metadata_percent != null and .metadata_percent != "")
    | "lvm_thin_pool_data_percent{vg=\"\(.vg_name)\",lv=\"\(.lv_name)\"} \(.data_percent)",
      "lvm_thin_pool_metadata_percent{vg=\"\(.vg_name)\",lv=\"\(.lv_name)\"} \(.metadata_percent)",
      "lvm_thin_pool_size_bytes{vg=\"\(.vg_name)\",lv=\"\(.lv_name)\"} \(.lv_size)"
  ' <<<"${lvs_json}" >> "${TMPFILE}" || scrape_success=0

  jq -r '
    .report[0].vg[]
    | "lvm_vg_free_bytes{vg=\"\(.vg_name)\"} \(.vg_free)"
  ' <<<"${vgs_json}" >> "${TMPFILE}" || scrape_success=0
fi

echo "lvm_thin_metrics_scrape_success ${scrape_success}" >> "${TMPFILE}"

mv -f "${TMPFILE}" "${OUTFILE}"
chmod 0644 "${OUTFILE}"

# Non-zero exit puts the unit into `failed`, which SystemdUnitFailed reports; otherwise the
# alert would keep evaluating the last file's stale numbers.
(( scrape_success == 1 ))
