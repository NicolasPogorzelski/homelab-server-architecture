#!/usr/bin/env bash
# Weekly comparison of what this repository says against what the fleet runs.
#
# The repository can be internally consistent and still describe a machine that
# does not exist. validate-repo.sh compares documents against files; this
# compares files against nodes. Both are needed and neither substitutes for the
# other: on 2026-09-08 every one of the 39 repository checks passed while
# thirteen playbooks reported drift on the live fleet, the first of them a
# deployed unit file still carrying an em dash the repository had replaced.
#
# Every playbook runs with --check, which changes nothing. Two of them are not
# strictly read-only and drift-sweep.conf names them and says why.
#
# What it cannot see: anything no role manages. That surface is the fleet
# snapshot's job (fleet-snapshot.yml), and the two are meant to be read together.
set -euo pipefail

REPO="${FLEET_DRIFT_REPO:-/home/devops/git/homelab-server-architecture}"
CONF="${FLEET_DRIFT_CONF:-${REPO}/ansible/drift-sweep.conf}"
# Both outputs land in one directory the invoking user owns, and the unit moves
# the metric into the collector afterwards with systemd's `+` privilege prefix.
# The sweep itself must NOT run as root: git refuses to operate on a repository
# owned by another user ("dubious ownership"), so preflight.yml fails on its
# first task and every playbook in the sweep reports no recap. Measured
# 2026-09-08 - the run came back with 25 errored playbooks and no drift at all,
# which is what a total failure looks like when nobody checks the reason.
REPORTDIR="${FLEET_DRIFT_REPORT_DIR:-/var/lib/fleet-drift}"
OUTDIR="${FLEET_DRIFT_TEXTFILE_DIR:-${REPORTDIR}}"
RULES_FILE="${REPO}/docker/monitoring/prometheus/rules/alert.rules.yml"
MONITORING_HOST="${FLEET_DRIFT_MONITORING_HOST:-monitoring}"
PROM_PORT="${FLEET_DRIFT_PROM_PORT:-9443}"

REPORT="${REPORTDIR}/report.txt"
mkdir -p "${OUTDIR}" "${REPORTDIR}"
umask 022

: > "${REPORT}"
say() { printf '%s\n' "$*" >> "${REPORT}"; }

say "fleet drift sweep - $(date -Is)"
say ""

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
if [[ ! -r "${CONF}" ]]; then
    echo "drift-sweep.conf not readable at ${CONF}" >&2
    exit 1
fi

# sed rather than a parser: see the note at the top of drift-sweep.conf.
mapfile -t PLAYBOOKS < <(sed -n '/^\[playbooks\]/,/^\[baseline\]/p' "${CONF}" \
                          | grep -E '^[a-z0-9-]+$' || true)

# baseline["playbook host"] = expected changed tasks
declare -A baseline=()
while read -r pb host count; do
    [[ -z "${pb:-}" ]] && continue
    baseline["${pb} ${host}"]="${count}"
done < <(sed -n '/^\[baseline\]/,$p' "${CONF}" | grep -E '^[a-z0-9-]+[[:space:]]+[a-z0-9-]+[[:space:]]+[0-9]+$' || true)

say "playbooks in sweep: ${#PLAYBOOKS[@]}"
say "baseline entries:   ${#baseline[@]}"
say ""

# ---------------------------------------------------------------------------
# The sweep
# ---------------------------------------------------------------------------
total_changed=0
total_unexpected=0
total_failed=0
total_unreachable=0
playbooks_errored=0
metric_rows=""

cd "${REPO}/ansible"

for pb in "${PLAYBOOKS[@]}"; do
    pb_file="playbooks/${pb}.yml"
    if [[ ! -f "${pb_file}" ]]; then
        say "MISSING  ${pb} - listed in drift-sweep.conf, no such playbook"
        playbooks_errored=$((playbooks_errored + 1))
        continue
    fi

    # --check never applies. rc is not the signal: measured 2026-09-08, every
    # run returned 0 whether it found drift or not, so the recap is read instead.
    out="$(ansible-playbook "${pb_file}" --check 2>&1)" || playbooks_errored=$((playbooks_errored + 1))
    recap="$(sed -n '/PLAY RECAP/,$p' <<< "${out}")"

    if [[ -z "${recap}" ]]; then
        say "NO RECAP ${pb} - the run produced no PLAY RECAP, treat as unmeasured"
        playbooks_errored=$((playbooks_errored + 1))
        continue
    fi

    pb_changed=0
    while read -r host changed failed unreachable; do
        [[ -z "${host:-}" ]] && continue
        pb_changed=$((pb_changed + changed))
        total_failed=$((total_failed + failed))
        total_unreachable=$((total_unreachable + unreachable))

        expected="${baseline["${pb} ${host}"]:-0}"
        unexpected=$((changed - expected))
        (( unexpected < 0 )) && unexpected=0
        total_unexpected=$((total_unexpected + unexpected))

        if (( changed > 0 )); then
            if (( unexpected > 0 )); then
                say "DRIFT    ${pb} ${host}: ${changed} changed, ${expected} held, ${unexpected} unexpected"
            else
                say "held     ${pb} ${host}: ${changed} changed, all of it in the baseline"
            fi
        fi
        if (( unreachable > 0 )); then
            say "UNREACH  ${pb} ${host}: not measured this run"
        fi
    done < <(awk '/: *ok=/ {
                    host=$1; c=0; f=0; u=0
                    for (i = 1; i <= NF; i++) {
                        split($i, kv, "=")
                        if (kv[1] == "changed")     c = kv[2]
                        if (kv[1] == "failed")      f = kv[2]
                        if (kv[1] == "unreachable") u = kv[2]
                    }
                    print host, c, f, u
                  }' <<< "${recap}")

    total_changed=$((total_changed + pb_changed))
    metric_rows+="fleet_drift_changed_tasks{playbook=\"${pb}\"} ${pb_changed}"$'\n'
done

# ---------------------------------------------------------------------------
# What Prometheus actually loaded, against what the repository holds
# ---------------------------------------------------------------------------
# The layer a --check run cannot reach. prometheus_config promotes the rules file
# and reloads; if the reload failed, the file on disk is right and the rules in
# memory are last week's - the shape of KE-16, where Apache served an expired
# certificate that had already been renewed beside it.
#
# curl --resolve rather than a plain URL: MagicDNS does not resolve on the control
# node. systemd-resolved answers first through nsswitch and does not know the
# Tailscale resolver, and `[!UNAVAIL=return]` stops the lookup before
# /etc/resolv.conf is ever read. The name is kept so SNI and certificate
# verification still apply.
rules_ok=0
rules_mismatch=0

export MONITORING_HOST
suffix="$(tailscale status --json 2>/dev/null \
          | python3 -c 'import sys,json; print(json.load(sys.stdin).get("MagicDNSSuffix",""))' 2>/dev/null || true)"
mon_ip="$(tailscale status --json 2>/dev/null | python3 -c '
import sys, json, os
host = os.environ["MONITORING_HOST"]
d = json.load(sys.stdin)
for p in d.get("Peer", {}).values():
    if p.get("HostName") == host:
        print(p["TailscaleIPs"][0])
        break
' 2>/dev/null || true)"

if [[ -z "${suffix}" || -z "${mon_ip}" || ! -r "${RULES_FILE}" ]]; then
    say ""
    say "RULES    not measured - no tailnet suffix, no monitoring address, or no rules file"
else
    url="https://${MONITORING_HOST}.${suffix}:${PROM_PORT}/api/v1/rules"
    live="$(curl -s --max-time 20 --resolve "${MONITORING_HOST}.${suffix}:${PROM_PORT}:${mon_ip}" "${url}" \
            | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for g in d.get("data", {}).get("groups", []):
    for r in g.get("rules", []):
        n = r.get("name")
        if n:
            print(n)
' 2>/dev/null | sort -u || true)"

    if [[ -z "${live}" ]]; then
        say ""
        say "RULES    not measured - Prometheus did not answer on ${PROM_PORT}"
    else
        repo_rules="$(grep -oE '^      - alert: [A-Za-z]+' "${RULES_FILE}" | sed 's/.*alert: //' | sort -u)"
        only_repo="$(comm -23 <(echo "${repo_rules}") <(echo "${live}") | tr '\n' ' ')"
        only_live="$(comm -13 <(echo "${repo_rules}") <(echo "${live}") | tr '\n' ' ')"
        rules_ok=1
        say ""
        if [[ -n "${only_repo// }" || -n "${only_live// }" ]]; then
            rules_mismatch=$(( $(wc -w <<< "${only_repo}") + $(wc -w <<< "${only_live}") ))
            say "RULES    mismatch between the repository and what Prometheus loaded"
            [[ -n "${only_repo// }" ]] && say "         in the repository, not loaded: ${only_repo}"
            [[ -n "${only_live// }" ]] && say "         loaded, not in the repository: ${only_live}"
        else
            say "RULES    repository and loaded rules agree ($(wc -l <<< "${live}") alerts)"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Metrics
# ---------------------------------------------------------------------------
# Same atomic-write discipline as the other collectors here: a temporary file in
# the same directory, so the rename cannot cross a filesystem, and a suffix
# node_exporter does not read while it is being written.
TMP="$(mktemp "${OUTDIR}/.fleet-drift.prom.XXXXXX")"
{
    echo "# HELP fleet_drift_last_run_timestamp_seconds Unix time of the last completed drift sweep."
    echo "# TYPE fleet_drift_last_run_timestamp_seconds gauge"
    echo "fleet_drift_last_run_timestamp_seconds $(date +%s)"
    echo "# HELP fleet_drift_changed_tasks Tasks a check run would change, per playbook."
    echo "# TYPE fleet_drift_changed_tasks gauge"
    printf '%s' "${metric_rows}"
    echo "# HELP fleet_drift_changed_total Tasks a check run would change across the sweep."
    echo "# TYPE fleet_drift_changed_total gauge"
    echo "fleet_drift_changed_total ${total_changed}"
    echo "# HELP fleet_drift_unexpected_total Changed tasks above the baseline in drift-sweep.conf."
    echo "# TYPE fleet_drift_unexpected_total gauge"
    echo "fleet_drift_unexpected_total ${total_unexpected}"
    echo "# HELP fleet_drift_playbooks_total Playbooks the sweep was configured to run."
    echo "# TYPE fleet_drift_playbooks_total gauge"
    echo "fleet_drift_playbooks_total ${#PLAYBOOKS[@]}"
    echo "# HELP fleet_drift_playbooks_errored Playbooks that produced no usable recap."
    echo "# TYPE fleet_drift_playbooks_errored gauge"
    echo "fleet_drift_playbooks_errored ${playbooks_errored}"
    echo "# HELP fleet_drift_hosts_unreachable Host results reported unreachable during the sweep."
    echo "# TYPE fleet_drift_hosts_unreachable gauge"
    echo "fleet_drift_hosts_unreachable ${total_unreachable}"
    echo "# HELP fleet_drift_rules_check_ok Whether the loaded alert rules could be compared at all."
    echo "# TYPE fleet_drift_rules_check_ok gauge"
    echo "fleet_drift_rules_check_ok ${rules_ok}"
    echo "# HELP fleet_drift_rules_mismatch Alert names present on only one side of that comparison."
    echo "# TYPE fleet_drift_rules_mismatch gauge"
    echo "fleet_drift_rules_mismatch ${rules_mismatch}"
} > "${TMP}"
mv "${TMP}" "${OUTDIR}/fleet-drift.prom"

say ""
say "changed ${total_changed}, unexpected ${total_unexpected}, errored ${playbooks_errored}, unreachable ${total_unreachable}"
cat "${REPORT}"
