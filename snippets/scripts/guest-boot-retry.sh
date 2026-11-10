#!/usr/bin/env bash
# Start the guests whose start failed at boot, a bounded number of times.
# Deploy to /usr/local/sbin/guest-boot-retry.sh; run once per boot by
# guest-boot-retry.service (ansible/roles/guest_boot_retry).
#
# pve-guests runs `startall` once and reports OK even when a guest failed to
# start; on 2026-11-10 lxc260 stayed down because the host's CIFS mount behind
# its bind mount failed while vm102's share was not yet reachable. See KE-27.
#
# A guest is retried when it is stopped, has `onboot: 1`, is no template and
# carries no lock. The unit runs after pve-guests has finished, so an onboot
# guest that is stopped at that point is one whose start failed. Guests are
# retried in their `startup: order=` sequence, so vm102 comes before its clients.
#
# Usage: guest-boot-retry.sh <attempts> <interval-seconds>
set -euo pipefail
# Without this, a failing `pvesh` inside $(...) would yield an empty list, and an
# empty list reads as "nothing to retry" - success where the API is down.
shopt -s inherit_errexit

ATTEMPTS="${1:?attempts missing}"
INTERVAL="${2:?interval missing}"
LOG_TAG="guest-boot-retry"

# Prints "<order> <type> <vmid>" per guest to start, lowest startup order first.
failed_guests() {
    local type ids id cfg order
    for type in lxc qemu; do
        ids=$(pvesh get "/nodes/localhost/${type}" --output-format json |
            jq -r '.[] | select(.status == "stopped"
                and ((.template // 0) | tostring) != "1"
                and (.lock // "") == "") | .vmid')
        for id in ${ids}; do
            cfg=$(pvesh get "/nodes/localhost/${type}/${id}/config" --output-format json)
            if jq -e '(.onboot // 0 | tostring) == "1"' > /dev/null <<< "${cfg}"; then
                # A guest without an order starts after all ordered ones, as in startall.
                order=$(jq -r '(.startup // "") | capture("order=(?<o>[0-9]+)").o // "9999"' <<< "${cfg}")
                printf '%s %s %s\n' "${order:-9999}" "${type}" "${id}"
            fi
        done
    done | sort -n -k1,1 -k3,3
}

start_guest() {
    case "$1" in
        lxc) pct start "$2" ;;
        qemu) qm start "$2" ;;
    esac
}

for (( attempt = 1; attempt <= ATTEMPTS; attempt++ )); do
    # Wait first: the failure this covers is a dependency (an SMB share on vm102,
    # a Tailscale route) that was still settling when startall reached the guest.
    sleep "${INTERVAL}"

    pending=$(failed_guests)
    if [[ -z "${pending}" ]]; then
        exit 0
    fi

    while read -r _order type id; do
        if start_guest "${type}" "${id}" > /dev/null 2>&1; then
            logger -t "${LOG_TAG}" "started ${type} ${id} (attempt ${attempt}/${ATTEMPTS})"
        else
            logger -t "${LOG_TAG}" "start of ${type} ${id} failed (attempt ${attempt}/${ATTEMPTS})"
        fi
    done <<< "${pending}"
done

pending=$(failed_guests)
if [[ -n "${pending}" ]]; then
    # Exit non-zero so the unit lands in `failed`, which SystemdUnitFailed reports.
    logger -t "${LOG_TAG}" -p user.err \
        "still not running after ${ATTEMPTS} attempts: $(awk '{print $2, $3}' <<< "${pending}" | paste -sd ',')"
    exit 1
fi
