#!/bin/bash
# VPS: inject only live LAN hosts into gre-pd; blackhole the rest of /24 locally.
# BGP still announces 79.172.242.0/24 — unused addresses never enter the GRE
# (stops internet scanner flood → lower Digi latency / max speedtests).
set -euo pipefail
ENV=/etc/pd-gre.env
[ -f "$ENV" ] && . "$ENV"
PEER="${INNER_PEER:-172.16.207.2}"
HOSTS="${PD_LAN_HOSTS:-79.172.242.1 79.172.242.2 79.172.242.3 79.172.242.10 79.172.242.48}"

ip route replace blackhole 79.172.242.0/24
for h in $HOSTS; do
  ip route replace "$h/32" via "$PEER" dev gre-pd
done
echo "pd-gre-lan-hosts: whitelist via gre-pd + blackhole unused /24 (BGP unchanged)"
