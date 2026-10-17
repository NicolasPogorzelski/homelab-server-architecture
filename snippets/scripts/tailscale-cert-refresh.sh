#!/usr/bin/env bash
#
# tailscale-cert-refresh.sh - keep a node's Tailscale TLS certificate fresh AND
# make the service that serves it pick the new one up.
#
# Nodes behind `tailscale serve` do not need this. Apache on lxc210 reads the
# certificate from /var/lib/tailscale/certs/ at start-up and keeps serving it
# from memory after tailscaled renews the file, so a reload is required (KE-16).
#
# `tailscale cert --min-validity` renews only below the threshold; the checksum
# comparison decides whether a reload is warranted.
#
set -euo pipefail

MIN_VALIDITY="${MIN_VALIDITY:-720h}"   # 30 days; Let's Encrypt certs live 90
CERT_DIR="/var/lib/tailscale/certs"
RELOAD_UNITS="${RELOAD_UNITS:-apache2}"  # space-separated

# The node's own MagicDNS name, without the trailing dot. Derived rather than
# configured: a hard-coded FQDN silently breaks if the node is renamed.
#
# Polled rather than read once: the Persistent=true timer catches up inside the
# boot window, when tailscaled runs but has not joined the tailnet and
# Self.DNSName is still empty. See KE-18.
FQDN=""
fqdn_deadline=90   # seconds; joining the tailnet is normally well under 30
fqdn_waited=0
while [ "${fqdn_waited}" -lt "${fqdn_deadline}" ]; do
    # `|| true` keeps `set -e`/`pipefail` from killing the script while
    # tailscaled is still starting: an unparseable or absent answer must cost
    # one iteration, not the whole run.
    FQDN="$(tailscale status --json 2>/dev/null \
        | python3 -c 'import sys,json; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' 2>/dev/null \
        || true)"
    if [ -n "${FQDN}" ]; then
        break
    fi
    sleep 2
    fqdn_waited=$((fqdn_waited + 2))
done
if [ -z "${FQDN}" ]; then
    echo "could not determine the node's MagicDNS name after ${fqdn_deadline}s" >&2
    exit 1
fi

CERT="${CERT_DIR}/${FQDN}.crt"
KEY="${CERT_DIR}/${FQDN}.key"

# Missing file hashes to the empty string, so a first run counts as "changed".
before="$(sha256sum "${CERT}" 2>/dev/null | cut -d' ' -f1 || true)"

# Both --cert-file and --key-file must be given: with neither set, `tailscale cert`
# writes DOMAIN.crt into the *current working directory*, which under systemd is /.
tailscale cert \
    --cert-file "${CERT}" \
    --key-file "${KEY}" \
    --min-validity "${MIN_VALIDITY}" \
    "${FQDN}"

after="$(sha256sum "${CERT}" 2>/dev/null | cut -d' ' -f1 || true)"

if [ "${before}" = "${after}" ]; then
    echo "certificate unchanged (valid for at least ${MIN_VALIDITY}) - no reload needed"
    exit 0
fi

echo "certificate renewed; reloading: ${RELOAD_UNITS}"
for unit in ${RELOAD_UNITS}; do
    # `reload`, not `restart`: Apache re-reads its certificates on a graceful
    # reload and existing connections survive.
    systemctl reload "${unit}"
    echo "reloaded ${unit}"
done

openssl x509 -in "${CERT}" -noout -enddate
