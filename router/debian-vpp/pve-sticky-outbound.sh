#!/bin/bash
# PVE sticky egress:
#   NEW locally-originated flows → 79.172.242.253 (Digi PPPoE + NAT)
#   inbound replies / unmarked   → 79.172.242.1 (GRE/PD)
set -euo pipefail
GRE_GW="${GRE_GW:-79.172.242.1}"
DIGI_GW="${DIGI_GW:-79.172.242.253}"
TABLE="${TABLE:-42}"
MARK="${MARK:-42}"
IF="${IF:-vmbr0}"

ip route replace "${DIGI_GW}/32" dev "$IF"
ip route replace default via "$GRE_GW" dev "$IF" onlink
ip route replace default via "$DIGI_GW" table "$TABLE"
ip rule del fwmark "$MARK" table "$TABLE" 2>/dev/null || true
ip rule add fwmark "$MARK" table "$TABLE" priority 1000

iptables -t mangle -N PVE_STICKY 2>/dev/null || iptables -t mangle -F PVE_STICKY
iptables -t mangle -C OUTPUT -j PVE_STICKY 2>/dev/null || iptables -t mangle -I OUTPUT 1 -j PVE_STICKY
# Never sticky-mark Tailscale / CGNAT mgmt / LAN — otherwise SSH smoke tests hang
# when Digi path flaps (curl waits forever on a blackhole).
iptables -t mangle -A PVE_STICKY -o tailscale0 -j RETURN
iptables -t mangle -A PVE_STICKY -d 100.64.0.0/10 -j RETURN
iptables -t mangle -A PVE_STICKY -d 79.172.242.0/24 -j RETURN
iptables -t mangle -A PVE_STICKY -j CONNMARK --restore-mark
iptables -t mangle -A PVE_STICKY -m mark --mark "$MARK" -j RETURN
iptables -t mangle -A PVE_STICKY -m conntrack --ctstate NEW -j MARK --set-mark "$MARK"
iptables -t mangle -A PVE_STICKY -m mark --mark "$MARK" -j CONNMARK --save-mark

sysctl -q -w net.ipv4.conf.all.rp_filter=0 || true
sysctl -q -w net.ipv4.conf."$IF".rp_filter=0 || true

# Only OUTPUT: do NOT mark PREROUTING on vmbr0 (inbound SYN would steal Digi mark).

echo "pve-sticky-outbound: NEW→${DIGI_GW} (mark ${MARK}/table ${TABLE}); replies→${GRE_GW}"
