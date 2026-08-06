#!/bin/bash
# Move PD host /32s back to gre-pd after Digi GRE6 is healthy.
set -euo pipefail
. /etc/pd-gre.env 2>/dev/null || true
. /etc/pd-vxlan-lab.conf 2>/dev/null || . /etc/pd/pd-vxlan-lab.conf 2>/dev/null || \
  . "$(dirname "$0")/pd-vxlan-lab.conf"

GRE_IF="${GRE_IF:-gre-pd}"
GRE_PEER="${INNER_PEER:-172.16.207.2}"
HOSTS="${HAIRPIN_HOSTS:-79.172.242.1 79.172.242.2 79.172.242.3 79.172.242.10}"

if ! ip link show "$GRE_IF" &>/dev/null; then
  echo "missing $GRE_IF — GRE not up yet" >&2
  exit 1
fi

for ip in $HOSTS; do
  ip route replace "$ip/32" via "$GRE_PEER" dev "$GRE_IF"
done
echo "pd-vxlan-prox-hairpin-vps-off: ${HOSTS} → via ${GRE_PEER} dev ${GRE_IF}"
