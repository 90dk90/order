#!/bin/bash
set -euo pipefail
ENV_FILE=/etc/pd-gre.env
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
DIGI_VTEP="${DIGI_VTEP:?DIGI_VTEP required}"
LOCAL_VTEP="${LOCAL_VTEP:-2a0e:97c0:4c1::60}"
INNER_LOCAL="${INNER_LOCAL:-172.16.207.1/30}"
INNER_PEER="${INNER_PEER:-172.16.207.2}"

modprobe ip6_gre 2>/dev/null || true

# Fast path: if tunnel exists with correct remote, only ensure routes
CUR=$(ip -6 tunnel show gre-pd 2>/dev/null | sed -n 's/.*remote \([^ ]*\).*/\1/p' || true)
if [ "$CUR" = "$DIGI_VTEP" ] && ip link show gre-pd >/dev/null 2>&1; then
  ip link set gre-pd mtu 1448 up 2>/dev/null || true
  ip addr replace "$INNER_LOCAL" dev gre-pd 2>/dev/null || true
  ip route replace 79.172.242.0/24 via "$INNER_PEER" dev gre-pd
else
  ip link del gre-pd 2>/dev/null || true
  ip -6 tunnel del gre-pd 2>/dev/null || true
  ip -6 tunnel add gre-pd mode ip6gre local "$LOCAL_VTEP" remote "$DIGI_VTEP" ttl 64 encaplimit none
  ip addr add "$INNER_LOCAL" dev gre-pd 2>/dev/null || true
  ip link set gre-pd mtu 1448 up
  ip route replace 79.172.242.0/24 via "$INNER_PEER" dev gre-pd
fi

sysctl -q -w net.ipv4.ip_forward=1
sysctl -q -w net.ipv4.conf.all.rp_filter=0
sysctl -q -w net.ipv4.conf.default.rp_filter=0
sysctl -q -w net.ipv4.conf.gre-pd.rp_filter=0 2>/dev/null || true
iptables -C FORWARD -i gre-pd -j ACCEPT 2>/dev/null || iptables -I FORWARD -i gre-pd -j ACCEPT
iptables -C FORWARD -o gre-pd -j ACCEPT 2>/dev/null || iptables -I FORWARD -o gre-pd -j ACCEPT
iptables -C FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
  iptables -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT

# Fallback SNAT only for NEW flows originating Digi→Internet (not inbound replies).
# Primary PVE egress is Digi sticky (79.172.242.253); keep this for other /24 hosts
# that still hairpin via GRE without Digi sticky marks.
iptables -t mangle -C FORWARD -i gre-pd -o eth0 -m conntrack --ctstate NEW -j MARK --set-mark 0x99 2>/dev/null || \
  iptables -t mangle -I FORWARD 1 -i gre-pd -o eth0 -m conntrack --ctstate NEW -j MARK --set-mark 0x99
iptables -t nat -C POSTROUTING -m mark --mark 0x99 -j MASQUERADE 2>/dev/null || \
  iptables -t nat -I POSTROUTING 1 -m mark --mark 0x99 -j MASQUERADE
# drop legacy blanket SNAT if present
iptables -t nat -D POSTROUTING -s 79.172.242.0/24 -o eth0 -j MASQUERADE 2>/dev/null || true

if [ -x /usr/local/sbin/pd-gre-harden-vps.sh ]; then
  /usr/local/sbin/pd-gre-harden-vps.sh || true
fi
echo "gre-pd ok remote=$DIGI_VTEP"
