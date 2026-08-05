#!/bin/bash
# Only known dedicated hosts enter gre-pd; rest of announced /24 is blackholed on the VPS.
# BGP still announces 79.172.242.0/24 — scanners die here instead of saturating Digi FOU.
set -euo pipefail
ENV=/etc/pd-gre.env
[ -f "$ENV" ] && . "$ENV"
PEER="${INNER_PEER:-172.16.207.2}"
HOSTS="${PD_LAN_HOSTS:-79.172.242.1 79.172.242.2 79.172.242.3 79.172.242.10}"
ip route replace blackhole 79.172.242.0/24
for h in $HOSTS; do
  ip route replace "$h/32" via "$PEER" dev gre-pd
done
echo "pd-gre-lan-hosts: blackhole /24 + hosts -> gre-pd ($HOSTS)"
