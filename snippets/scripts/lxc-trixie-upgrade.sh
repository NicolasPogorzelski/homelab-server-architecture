#!/usr/bin/env bash
# Runs on the Proxmox host. Upgrades one Debian 12 LXC to Debian 13.
#   lxc-trixie-upgrade.sh <ctid> check   - sources that would change, trixie Release files reachable
#   lxc-trixie-upgrade.sh <ctid> apply [keep] - vzdump, switch sources, full-upgrade, reboot, verify
#   lxc-trixie-upgrade.sh <ctid> rollback - print the restore command for the backup taken by apply
# The upgrade runs inside the container as a transient unit, so a tailscaled restart in the
# container cannot cut dpkg off halfway; pct exec does not depend on the container's network.
set -uo pipefail
CT="$1"; MODE="${2:-check}"; KEEP="${3:-}"   # keep: no autoremove, for packages still in use (PostgreSQL 15, PHP 8.2)
X() { pct exec "$CT" -- "$@"; }

FILES=$(X bash -c 'grep -rlE "bookworm" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null')

case "$MODE" in
check)
    echo "ct$CT $(X bash -c '. /etc/os-release; echo $PRETTY_NAME')"
    for f in $FILES; do echo "  $f: $(X grep -cE bookworm "$f") line(s)"; done
    for u in $(X bash -c 'grep -rhoE "https?://[^ ]+" /etc/apt/sources.list /etc/apt/sources.list.d/ | sort -u'); do
        u=${u%/}
        case "$u" in
            *security.debian.org*) r="$u/dists/trixie-security/Release" ;;
            *) r="$u/dists/trixie/Release" ;;
        esac
        printf '  %-55s %s\n' "$r" "$(curl -s -o /dev/null -w '%{http_code}' "$r")"
    done
    echo "  free on /: $(X df -h / | awk 'NR==2{print $4}')"
    ;;
apply)
    # vzdump instead of pct snapshot: the bind mount points make snapshots unavailable. Its
    # own directory, so the daily job's pruning never counts or removes these archives.
    mountpoint -q /mnt/vzdump || { echo "/mnt/vzdump not mounted"; exit 1; }
    mkdir -p /mnt/vzdump/pre-trixie
    vzdump "$CT" --mode snapshot --compress zstd --dumpdir /mnt/vzdump/pre-trixie >/dev/null 2>&1 || { echo "vzdump failed"; exit 1; }
    echo "ct$CT backup: $(ls -1t /mnt/vzdump/pre-trixie/vzdump-lxc-$CT-*.tar.zst | head -1)"
    for f in $FILES; do X sed -i 's/\bbookworm\b/trixie/g' "$f"; done
    AR='apt-get -y autoremove --purge && '; [ "$KEEP" = keep ] && AR=''
    X systemd-run --unit=trixie-upgrade --wait --collect --setenv=DEBIAN_FRONTEND=noninteractive \
        /bin/bash -c 'apt-get update -q && apt-get -y -q -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef full-upgrade && '"$AR"'apt-get clean' \
        >/dev/null 2>&1
    rc=$?
    echo "ct$CT upgrade rc=$rc"
    X bash -c 'journalctl -u trixie-upgrade --no-pager -o cat | grep -E "^(E:|W:)|upgraded," | tail -5'
    [ "$rc" = 0 ] || { echo "upgrade failed; rollback with: $0 $CT rollback"; exit 1; }
    pct reboot "$CT" --timeout 120
    for i in $(seq 1 30); do sleep 4; X systemctl is-system-running 2>/dev/null | grep -qE "running|degraded" && break; done
    sleep 20
    echo "ct$CT $(X bash -c '. /etc/os-release; echo $PRETTY_NAME') | state $(X systemctl is-system-running) | failed: $(X systemctl --failed --no-legend --plain | awk '{print $1}' | tr '\n' ' ')"
    X bash -c 'command -v docker >/dev/null && docker ps -a --format "  {{.Names}} {{.Status}}"'
    X bash -c 'tailscale status --self --peers=false 2>&1 | head -1 | sed -E "s/100\.[0-9.]+/<ts-ip>/"'
    X bash -c 'apt-get -s full-upgrade | grep -c ^Inst | sed "s/^/  pending after: /"'
    ;;
rollback)
    a=$(ls -1t /mnt/vzdump/pre-trixie/vzdump-lxc-$CT-*.tar.zst | head -1)
    echo "restore with: pct stop $CT && pct restore $CT $a --storage local-lvm --force && pct start $CT"
    ;;
esac
