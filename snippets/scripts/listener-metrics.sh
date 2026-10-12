#!/bin/bash
# listener-metrics.sh - the platform binding rule as a node_exporter metric.
#
# Deployed by the listener_metrics role. Every listening socket on the node is
# classified by its address: loopback and the Tailscale overlay (100.64.0.0/10,
# fd7a:115c:a1e0::/48) satisfy the rule, anything else - a wildcard, a LAN
# address, a link-local one - does not, unless its protocol and port are allowed
# on record in the allow file. Each remaining socket becomes one series of
# node_listener_outside_binding_rule, and the rule ListenerOutsideBindingRule
# fires on it.
#
# Usage: listener-metrics.sh <textfile-dir> <allow-file>
# Allow file: "proto port" or "proto * process" per line, '#' starts a comment.
# The second form allows one process on any port, for a daemon whose sockets
# take ephemeral ports by design.

set -euo pipefail

out_dir=${1:?usage: listener-metrics.sh <textfile-dir> <allow-file>}
allow_file=${2:?usage: listener-metrics.sh <textfile-dir> <allow-file>}

declare -A allowed=()
while read -r proto port proc _; do
    [[ -z "${proto:-}" || "$proto" == \#* ]] && continue
    if [[ "$port" == "*" ]]; then
        [[ -n "${proc:-}" && "$proc" != \#* ]] || { echo "allow file: '$proto *' needs a process" >&2; exit 1; }
        allowed["$proto/*/$proc"]=1
    else
        allowed["$proto/$port"]=1
    fi
done < "$allow_file"

conforms() {
    local addr=$1 o2
    case "$addr" in
        127.*|::1|::ffff:127.*) return 0 ;;
        fd7a:115c:a1e0:*) return 0 ;;
        100.*)
            o2=${addr#100.}; o2=${o2%%.*}
            (( o2 >= 64 && o2 <= 127 )) && return 0 ;;
    esac
    return 1
}

tmp=$(mktemp "$out_dir/.listeners.prom.XXXXXX")
trap 'rm -f "$tmp"' EXIT

{
    echo "# HELP node_listener_outside_binding_rule A listening socket bound neither to loopback nor to the Tailscale overlay, and not allowed on record for this node."
    echo "# TYPE node_listener_outside_binding_rule gauge"
    # -H no header, -l listening, -n numeric, -t/-u TCP and UDP, -p owning process.
    ss -Hlntup | while read -r proto _ _ _ local _ process; do
        port=${local##*:}
        addr=${local%:*}
        addr=${addr%%\%*}
        addr=${addr#[}
        addr=${addr%]}
        conforms "$addr" && continue
        [[ -n "${allowed[$proto/$port]:-}" ]] && continue
        name=$(sed -nE 's/^users:\(\("([^"]+)".*/\1/p' <<< "${process:-}")
        [[ -n "$name" && -n "${allowed[$proto/*/$name]:-}" ]] && continue
        printf 'node_listener_outside_binding_rule{proto="%s",address="%s",port="%s",process="%s"} 1\n' \
            "$proto" "$addr" "$port" "${name:-unknown}"
    done | sort -u
    echo "# HELP node_listener_check_timestamp_seconds When listener-metrics.sh last completed."
    echo "# TYPE node_listener_check_timestamp_seconds gauge"
    echo "node_listener_check_timestamp_seconds $(date +%s)"
} > "$tmp"

chmod 0644 "$tmp"
mv "$tmp" "$out_dir/listeners.prom"
trap - EXIT
