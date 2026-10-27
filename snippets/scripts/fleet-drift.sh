#!/usr/bin/env bash
# Weekly comparison of what this repository says against what the fleet runs.
#
# validate-repo.sh compares documents against files; this compares files against
# nodes. Every playbook runs with --check; the ones that are not strictly
# read-only are named in drift-sweep.conf with the reason.
#
# Anything no role manages is invisible here; the fleet snapshot
# (fleet-snapshot.yml) covers that surface.
set -euo pipefail

REPO="${FLEET_DRIFT_REPO:-/home/devops/git/homelab-server-architecture}"
CONF="${FLEET_DRIFT_CONF:-${REPO}/ansible/drift-sweep.conf}"
# Both outputs land in a directory the invoking user owns; the unit moves the
# metric into the collector with systemd's `+` prefix. The sweep must not run as
# root: git refuses a repository owned by another user ("dubious ownership"), so
# preflight.yml fails and every playbook reports no recap.
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

    # rc is not the drift signal (a check run returns 0 with or without drift),
    # so the recap is read. A non-zero rc is still reported by playbook name.
    rc=0
    out="$(ansible-playbook "${pb_file}" --check 2>&1)" || rc=$?
    if [[ ${rc} -ne 0 ]]; then
        # The task that failed, or Ansible's first error line when no task ran. Without
        # it, a refused preflight gate read as 44 bare "exited 2" lines.
        reason="$(awk '/^TASK \[/ { t = $0 } /^fatal:/ { print t; exit }' <<< "${out}" \
                  | sed -E 's/^TASK \[(.*)\] \**$/\1/')"
        [[ -z "${reason}" ]] && reason="$(grep -m1 -E '^(\[ERROR\]|ERROR!)' <<< "${out}" | cut -c1-160 || true)"
        say "ERRORED  ${pb} - ansible-playbook exited ${rc}${reason:+ at: ${reason}}"
        playbooks_errored=$((playbooks_errored + 1))
    fi
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
# A --check run cannot see a failed reload: the rules file on disk is right while
# Prometheus still holds the old rules in memory (the KE-16 pattern).
#
# curl --resolve takes the address from `tailscale status`, so the check does not
# depend on name resolution on the control node
# (docs/decisions/magicdns-and-systemd-resolved.md); the name keeps SNI and
# certificate verification.
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
        if n and r.get("type") == "alerting":
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
# Atomic write: a temporary file in the same directory (rename cannot cross a
# filesystem) under a name node_exporter does not read.
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
# mktemp creates 0600 and mv preserves it; node_exporter silently skips a file it
# cannot read, and absent metrics would read like no drift.
chmod 0644 "${TMP}"
mv "${TMP}" "${OUTDIR}/fleet-drift.prom"

say ""
say "changed ${total_changed}, unexpected ${total_unexpected}, errored ${playbooks_errored}, unreachable ${total_unreachable}"
cat "${REPORT}"
