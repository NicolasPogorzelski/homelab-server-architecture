#!/usr/bin/env bash
# Start the containers whose start failed at boot, a bounded number of times.
# Deploy to /usr/local/sbin/docker-boot-retry.sh; run once per boot by
# docker-boot-retry.service (ansible/roles/docker_boot_retry).
#
# Docker applies a restart policy only to a container that has started
# successfully once. A container whose start fails - on vm100, a bind mount onto
# an automount whose CIFS mount was refused - stays exited until someone runs
# `docker start`. This script is that someone, at boot and nowhere else.
#
# A container is retried when it is not running, carries a restart policy that
# asks for it to run (always, unless-stopped), and has a non-empty State.Error.
# `docker stop` leaves State.Error empty, so a container stopped on purpose is
# never touched.
#
# Usage: docker-boot-retry.sh <attempts> <interval-seconds>
set -euo pipefail
# Without this, a failing `docker` inside $(...) would yield an empty list, and
# an empty list reads as "nothing to retry" - success where the daemon is down.
shopt -s inherit_errexit

ATTEMPTS="${1:?attempts missing}"
INTERVAL="${2:?interval missing}"
LOG_TAG="docker-boot-retry"

failed_containers() {
    local ids
    ids=$(docker ps -aq --filter status=exited --filter status=created)
    if [[ -z "${ids}" ]]; then
        return 0
    fi
    # shellcheck disable=SC2086 # one argument per container id is the intent
    docker inspect --format '{{.Name}}|{{.HostConfig.RestartPolicy.Name}}|{{.State.Error}}' ${ids} |
        awk -F'|' '($2 == "always" || $2 == "unless-stopped") && $3 != "" { sub(/^\//, "", $1); print $1 }'
}

for (( attempt = 1; attempt <= ATTEMPTS; attempt++ )); do
    # Wait first: the storage VM boots alongside this node, and the failure this
    # covers is a mount refused while its SMB server was still settling.
    sleep "${INTERVAL}"

    pending=$(failed_containers)
    if [[ -z "${pending}" ]]; then
        exit 0
    fi

    while read -r name; do
        if docker start "${name}" > /dev/null 2>&1; then
            logger -t "${LOG_TAG}" "started ${name} (attempt ${attempt}/${ATTEMPTS})"
        else
            logger -t "${LOG_TAG}" "start of ${name} failed (attempt ${attempt}/${ATTEMPTS})"
        fi
    done <<< "${pending}"
done

pending=$(failed_containers)
if [[ -n "${pending}" ]]; then
    # Exit non-zero so the unit lands in `failed`, which SystemdUnitFailed reports.
    logger -t "${LOG_TAG}" -p user.err "still not running after ${ATTEMPTS} attempts: ${pending//$'\n'/ }"
    exit 1
fi
