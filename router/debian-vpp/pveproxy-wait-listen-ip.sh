#!/bin/bash
# Wait until pveproxy LISTEN_IP exists on an interface (usually Tailscale).
# Used as ExecStartPre so boot order does not race tailscaled.
set -euo pipefail
. /etc/default/pveproxy
LISTEN_IP="${LISTEN_IP:?LISTEN_IP missing in /etc/default/pveproxy}"
TRIES="${TRIES:-90}"
for i in $(seq 1 "$TRIES"); do
  if ip -4 -o addr show 2>/dev/null | awk '{print $4}' | grep -q "^${LISTEN_IP}/"; then
    exit 0
  fi
  sleep 1
done
echo "pveproxy-wait-listen-ip: ${LISTEN_IP} not present after ${TRIES}s" >&2
exit 1
