#!/bin/bash
# VPS side of Proximus VXLAN hairpin for PD /24 while Digi GRE6 is down.
# Moves host /32s onto vxlan-lab (away from gre-pd). Does not touch Bird/BGP.
set -euo pipefail
. /etc/pd-vxlan-lab.conf 2>/dev/null || . /etc/pd/pd-vxlan-lab.conf 2>/dev/null || \
  . "$(dirname "$0")/pd-vxlan-lab.conf"

VXLAN_IF="${HAIRPIN_VXLAN_IF:-vxlan-lab}"
DIGI_INNER="${LAB_DIGI:-172.16.208.2}"
HOSTS="${HAIRPIN_HOSTS:-79.172.242.1 79.172.242.2 79.172.242.3 79.172.242.10}"

if ! ip link show "$VXLAN_IF" &>/dev/null; then
  echo "missing $VXLAN_IF — run pd-vxlan-lab-vps.sh first" >&2
  exit 1
fi

sysctl -q -w net.ipv4.ip_forward=1
sysctl -q -w net.ipv4.conf.all.rp_filter=0
sysctl -q -w "net.ipv4.conf.${VXLAN_IF}.rp_filter=0" 2>/dev/null || true

for ip in $HOSTS; do
  ip route replace "$ip/32" via "$DIGI_INNER" dev "$VXLAN_IF"
done

iptables -C FORWARD -o "$VXLAN_IF" -j ACCEPT 2>/dev/null || iptables -I FORWARD 2 -o "$VXLAN_IF" -j ACCEPT
iptables -C FORWARD -i "$VXLAN_IF" -j ACCEPT 2>/dev/null || iptables -I FORWARD 3 -i "$VXLAN_IF" -j ACCEPT
# Keep SNAT for return-path when peers don't have PD route (same as GRE era)
iptables -t nat -C POSTROUTING -s 79.172.242.0/24 -o eth0 -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -s 79.172.242.0/24 -o eth0 -j MASQUERADE

if command -v netfilter-persistent >/dev/null 2>&1; then
  netfilter-persistent save 2>/dev/null || true
elif [ -d /etc/iptables ]; then
  iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
fi

echo "pd-vxlan-prox-hairpin-vps: ${HOSTS} → via ${DIGI_INNER} dev ${VXLAN_IF}"
for ip in $HOSTS; do
  ping -c 1 -W 2 "$ip" 2>&1 | tail -2 || true
done
