#!/bin/bash
# Move PD /24 cover back to gre-pd after Digi GRE6 is healthy.
set -euo pipefail
. /etc/pd-gre.env 2>/dev/null || true
. /etc/pd-vxlan-lab.conf 2>/dev/null || . /etc/pd/pd-vxlan-lab.conf 2>/dev/null || \
  . "$(dirname "$0")/pd-vxlan-lab.conf"

GRE_IF="${GRE_IF:-gre-pd}"
GRE_PEER="${INNER_PEER:-172.16.207.2}"
LAN_PREFIX="${LAN_PREFIX:-79.172.242.0/24}"

if ! ip link show "$GRE_IF" &>/dev/null; then
  echo "missing $GRE_IF — GRE not up yet" >&2
  exit 1
fi

ip route replace "$LAN_PREFIX" via "$GRE_PEER" dev "$GRE_IF"
echo "pd-vxlan-prox-hairpin-vps-off: ${LAN_PREFIX} → via ${GRE_PEER} dev ${GRE_IF}"
