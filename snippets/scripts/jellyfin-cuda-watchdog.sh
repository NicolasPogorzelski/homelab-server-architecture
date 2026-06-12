#!/usr/bin/env bash
# Watchdog: restart Jellyfin if CUDA access is lost.
# Deploy to /usr/local/sbin/jellyfin-cuda-watchdog.sh on VM100.
# Run via cron every 30 minutes (see docs/services/jellyfin.md).
set -euo pipefail

CONTAINER="jellyfin"
LOG_TAG="jellyfin-cuda-watchdog"

# Do nothing if the container is not running
if ! docker ps --filter "name=^${CONTAINER}$" --filter "status=running" \
       --format "{{.Names}}" | grep -q "^${CONTAINER}$"; then
    logger -t "${LOG_TAG}" "container not running — skipping"
    exit 0
fi

# nvidia-smi inside the container is the authoritative CUDA health check
if docker exec "${CONTAINER}" nvidia-smi > /dev/null 2>&1; then
    exit 0
fi

logger -t "${LOG_TAG}" "CUDA access lost — restarting ${CONTAINER}"
docker restart "${CONTAINER}"
logger -t "${LOG_TAG}" "${CONTAINER} restarted successfully"
