#!/usr/bin/env bash
# Export LVM thin-pool utilisation to the node_exporter textfile collector.
#
# Why a textfile collector and not an existing exporter: a thin pool is a block-layer object
# with no filesystem and no mount point, so node_filesystem_* cannot observe it -- the metric
# a DiskSpaceCritical-style rule would need simply does not exist. This is the KE-7 failure
# class (thin-pool overflow corrupting packages mid-apt), which has hit this platform once.
# On 2026-08-10 pve/data was found at 92.55% by hand, with no rule capable of catching it.
#
# lvm_vg_free_bytes is exported alongside on purpose: when the pool fills, the reflex is
# `lvextend`, and that only works if the VG has unallocated extents. On this host VFree is 0,
# so the reflex fails and the runbook's real options are shrinking root/swap or adding a PV.
# An alert that fires without telling you the escape hatch is shut is only half an alert.
set -euo pipefail

OUTDIR="/var/lib/node_exporter/textfile_collector"
OUTFILE="${OUTDIR}/lvm-thin.prom"
mkdir -p "${OUTDIR}"

# node_exporter must be able to read the file; it reads *.prom only, so the temp file below
# is invisible to it while being written.
umask 022

# mktemp in the *same* directory as the target: `mv` is only atomic within one filesystem.
TMPFILE="$(mktemp "${OUTDIR}/lvm-thin.prom.XXXXXX")"

# The predecessor SMART collector has no cleanup trap, which is why ten orphaned
# smart.prom.XXXXXX files dating back to 2025-12 sit in this directory: with `set -e`, any
# failure between mktemp and mv leaks the temp file. Clean up on every exit path.
trap 'rm -f "${TMPFILE}"' EXIT

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
  # Filter on metadata_percent, not data_percent. Thin *volumes* (vm-210-disk-0 and friends)
  # also report data_percent, so filtering on that emitted twelve mislabelled series plus an
  # empty metadata_percent value -- and a metric line with no value is a parse error that makes
  # node_exporter discard the entire file. Only a thin *pool* carries metadata_percent.
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
trap - EXIT

# Non-zero exit puts the unit into `failed`, which node_exporter --collector.systemd exports
# and SystemdUnitFailed picks up. A collector that dies quietly would leave the last .prom
# file in place and the alert would keep evaluating stale numbers -- so fail loudly instead.
(( scrape_success == 1 ))
