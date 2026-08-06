#!/bin/bash
# VPS: whole customer /24 via gre-pd (no per-DIP /32, no local blackhole).
# BGP still announces 79.172.242.0/24 unchanged.
set -euo pipefail
ENV=/etc/pd-gre.env
[ -f "$ENV" ] && . "$ENV"
PEER="${INNER_PEER:-172.16.207.2}"
LAN_PREFIX="${LAN_PREFIX:-79.172.242.0/24}"

# Drop legacy per-DIP / blackhole model if present
ip route del blackhole 79.172.242.0/24 2>/dev/null || true
ip route replace "$LAN_PREFIX" via "$PEER" dev gre-pd
echo "pd-gre-lan-hosts: ${LAN_PREFIX} via gre-pd (cover24, BGP unchanged)"
