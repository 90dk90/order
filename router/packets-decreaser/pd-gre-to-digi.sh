#!/bin/bash
set -euo pipefail
DIGI_VTEP_FILE=/etc/pd-gre.env
if [ -f "$DIGI_VTEP_FILE" ]; then
  # shellcheck disable=SC1090
  . "$DIGI_VTEP_FILE"
fi
DIGI_VTEP="${DIGI_VTEP:-2a01:4700:80ff:ffff::6440:9222}"
LOCAL_VTEP="${LOCAL_VTEP:-2a0e:97c0:4c1::60}"
INNER_LOCAL="${INNER_LOCAL:-172.16.207.1/30}"
INNER_PEER="${INNER_PEER:-172.16.207.2}"

modprobe ip6_gre 2>/dev/null || true
ip link del gre-pd 2>/dev/null || true
ip -6 tunnel del gre-pd 2>/dev/null || true
ip -6 tunnel add gre-pd mode ip6gre local "$LOCAL_VTEP" remote "$DIGI_VTEP" ttl 64 encaplimit none
ip addr add "$INNER_LOCAL" dev gre-pd 2>/dev/null || true
ip link set gre-pd mtu 1448 up
ip route replace 79.172.242.0/24 via "$INNER_PEER" dev gre-pd
sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null
sysctl -w net.ipv4.conf.gre-pd.rp_filter=0 >/dev/null
iptables -C FORWARD -i gre-pd -j ACCEPT 2>/dev/null || iptables -I FORWARD -i gre-pd -j ACCEPT
iptables -C FORWARD -o gre-pd -j ACCEPT 2>/dev/null || iptables -I FORWARD -o gre-pd -j ACCEPT
