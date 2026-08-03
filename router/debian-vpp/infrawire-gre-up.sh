#!/bin/sh
set -eu

if [ -r /run/vpp-tap30-ipv6.env ]; then
  # shellcheck disable=SC1091
  . /run/vpp-tap30-ipv6.env
fi

SRC_VTEP="${VXLAN_LOCAL_IP6:-2a01:4700:8080:6400::2}"
DST_VTEP=2a10:4646:500::1
LOCAL_IP=172.16.206.2/30
PEER_IP=172.16.206.1
HOST_IF=vpp-gre-infra
UNDERLAY_HOST=vpp6-host

for i in $(seq 1 60); do
  ip link show ppp0 >/dev/null 2>&1 && break
  sleep 1
done

# Critical: VTEP must NOT be local on ppp0, or GRE returns never reach VPP.
# Digi PPP keeps its own 80ff:ffff address; we only forward ::2 into VPP.
ip -6 addr del "$SRC_VTEP/128" dev ppp0 2>/dev/null || true
ip -6 route replace "$SRC_VTEP/128" dev "$UNDERLAY_HOST" metric 1
ip -6 route replace "$DST_VTEP/128" dev ppp0 metric 5

# Remove legacy Linux GRE if present (conflicts with VPP gre0)
ip link del gre-infra 2>/dev/null || true

sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
sysctl -w net.ipv6.conf.ppp0.forwarding=1 >/dev/null
sysctl -w net.ipv6.conf."$UNDERLAY_HOST".forwarding=1 >/dev/null
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null
sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null

# Wait LCP host iface from VPP
for i in $(seq 1 60); do
  ip link show "$HOST_IF" >/dev/null 2>&1 && break
  sleep 1
done
if ip link show "$HOST_IF" >/dev/null 2>&1; then
  ip link set "$HOST_IF" up
  ip link set "$HOST_IF" mtu 1476
  ip addr replace "$LOCAL_IP" dev "$HOST_IF"
  ip route replace "$PEER_IP/32" dev "$HOST_IF"
  sysctl -w net.ipv4.conf."$HOST_IF".rp_filter=0 >/dev/null || true
fi

# Optional host policy routing (control-plane / diagnostics)
ip route replace default via "$PEER_IP" dev "$HOST_IF" table 210699 2>/dev/null || true
ip route replace "$PEER_IP/32" dev "$HOST_IF" table 210699 2>/dev/null || true
ip rule del from 79.172.242.0/24 table 210699 2>/dev/null || true
ip rule add from 79.172.242.0/24 table 210699 priority 100 2>/dev/null || true
