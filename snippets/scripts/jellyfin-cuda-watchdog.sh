#!/usr/bin/env bash
# Watchdog: restart Jellyfin when CUDA access is lost (KE-10), but not under a
# stream that does not need the GPU.
#
# Deployed by the jellyfin_watchdog role to /usr/local/sbin/ on vm100. Edit this
# file, never the copy on the node.
#
# A restart ends every running stream, direct play included, and direct play
# never touches the GPU. So when CUDA is gone the script asks Jellyfin who is
# playing:
#   - nobody playing                      -> restart now
#   - somebody transcoding video          -> restart now; that stream already
#                                            depends on the GPU that is gone
#   - only direct play or direct stream   -> hold, and look again next minute
#   - Jellyfin's API does not answer      -> restart, the behaviour before the
#                                            hold existed
# The timer runs every minute, so a held restart happens within a minute of the
# last direct stream ending.
#
# State goes to the textfile collector so a held restart is visible instead of
# silent: jellyfin_cuda_ok, jellyfin_watchdog_restart_held and the time of the
# last restart.
set -euo pipefail

CONTAINER="jellyfin"
LOG_TAG="jellyfin-cuda-watchdog"
ENV_FILE="/etc/jellyfin-cuda-watchdog/env"          # JELLYFIN_URL
# The API key travels as a header file (curl -H @file), never as an argument, so
# it does not appear in the process list while curl runs. Mode 0600, root.
HEADER_FILE="/etc/jellyfin-cuda-watchdog/auth-header"
TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"
METRIC_FILE="${TEXTFILE_DIR}/jellyfin_watchdog.prom"
LAST_RESTART_FILE="/var/lib/jellyfin-cuda-watchdog/last_restart"

write_metrics() {
    local cuda_ok="$1" held="$2" last_restart=0
    [ -r "${LAST_RESTART_FILE}" ] && last_restart="$(cat "${LAST_RESTART_FILE}")"
    # Written to a temp name the collector ignores, then renamed, so a scrape
    # never reads half a file.
    cat > "${METRIC_FILE}.tmp" <<EOF
# HELP jellyfin_cuda_ok Whether nvidia-smi succeeds inside the Jellyfin container.
# TYPE jellyfin_cuda_ok gauge
jellyfin_cuda_ok ${cuda_ok}
# HELP jellyfin_watchdog_restart_held Whether a restart is being held back for direct streams.
# TYPE jellyfin_watchdog_restart_held gauge
jellyfin_watchdog_restart_held ${held}
# HELP jellyfin_watchdog_last_restart_timestamp_seconds When the watchdog last restarted Jellyfin.
# TYPE jellyfin_watchdog_last_restart_timestamp_seconds gauge
jellyfin_watchdog_last_restart_timestamp_seconds ${last_restart}
EOF
    mv "${METRIC_FILE}.tmp" "${METRIC_FILE}"
}

restart() {
    logger -t "${LOG_TAG}" "CUDA access lost - restarting ${CONTAINER} ($1)"
    docker restart "${CONTAINER}" > /dev/null
    mkdir -p "$(dirname "${LAST_RESTART_FILE}")"
    date +%s > "${LAST_RESTART_FILE}"
    logger -t "${LOG_TAG}" "${CONTAINER} restarted"
    write_metrics 0 0
}

# Do nothing if the container is not running; nothing to measure either.
if ! docker ps --filter "name=^${CONTAINER}$" --filter "status=running" \
       --format "{{.Names}}" | grep -q "^${CONTAINER}$"; then
    logger -t "${LOG_TAG}" "container not running - skipping"
    exit 0
fi

# nvidia-smi inside the container is the authoritative CUDA health check.
if docker exec "${CONTAINER}" nvidia-smi > /dev/null 2>&1; then
    write_metrics 1 0
    exit 0
fi

# shellcheck source=/dev/null
. "${ENV_FILE}"

# Sessions with something playing. A video transcode is a session whose
# TranscodingInfo says the video is not passed through; remuxes and audio-only
# transcodes keep IsVideoDirect true and do not use the GPU for video.
if ! sessions="$(curl -fsS --max-time 10 \
        -H @"${HEADER_FILE}" \
        "${JELLYFIN_URL}/Sessions")"; then
    restart "sessions API did not answer"
    exit 0
fi

playing="$(jq '[.[] | select(.NowPlayingItem != null)] | length' <<< "${sessions}")"
transcoding="$(jq '[.[] | select(.NowPlayingItem != null)
                        | select(.TranscodingInfo != null and .TranscodingInfo.IsVideoDirect == false)]
                   | length' <<< "${sessions}")"

if [ "${playing}" -eq 0 ]; then
    restart "no stream playing"
elif [ "${transcoding}" -gt 0 ]; then
    restart "${transcoding} of ${playing} streams transcode video"
else
    logger -t "${LOG_TAG}" "CUDA access lost - restart held, ${playing} direct stream(s) playing"
    write_metrics 0 1
fi
