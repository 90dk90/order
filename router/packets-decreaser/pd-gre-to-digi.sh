#!/bin/bash
# VPS hub: gre-pd toward Digi (ip6gre) or Proximus (gre v4, optionally FOU/UDP).
set -euo pipefail
ENV_FILE=/etc/pd-gre.env
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
DIGI_VTEP="${DIGI_VTEP:?DIGI_VTEP required}"
LOCAL_VTEP="${LOCAL_VTEP:-2a0e:97c0:4c1::60}"
LOCAL_VTEP_V4="${LOCAL_VTEP_V4:-77.90.4.48}"
INNER_LOCAL="${INNER_LOCAL:-172.16.207.1/30}"
INNER_PEER="${INNER_PEER:-172.16.207.2}"
GRE_FAMILY="${GRE_FAMILY:-}"
GRE_FOU="${GRE_FOU:-0}"
FOU_PORT="${FOU_PORT:-4754}"
MTU=1448

if [ -z "$GRE_FAMILY" ]; then
  case "$DIGI_VTEP" in
    *:*) GRE_FAMILY=ip6 ;;
    *) GRE_FAMILY=ip4 ;;
  esac
fi

modprobe gre 2>/dev/null || true
modprobe ip_gre 2>/dev/null || true
modprobe ip6_gre 2>/dev/null || true

if [ "$GRE_FAMILY" = ip4 ] && [ "$GRE_FOU" = 1 ]; then
  modprobe fou 2>/dev/null || true
  ip fou del port "$FOU_PORT" 2>/dev/null || true
  ip fou add port "$FOU_PORT" ipproto 47
  iptables -C INPUT -p udp --dport "$FOU_PORT" -j ACCEPT 2>/dev/null || \
    iptables -I INPUT 1 -p udp --dport "$FOU_PORT" -j ACCEPT
  MTU=1400
fi

need_rebuild=1
if [ "$GRE_FAMILY" = ip6 ]; then
  CUR=$(ip -6 tunnel show gre-pd 2>/dev/null | sed -n 's/.*remote \([^ ]*\).*/\1/p' || true)
  [ "$CUR" = "$DIGI_VTEP" ] && ip link show gre-pd >/dev/null 2>&1 && need_rebuild=0
else
  CUR=$(ip tunnel show gre-pd 2>/dev/null | sed -n 's/.*remote \([^ ]*\).*/\1/p' || true)
  [ -z "$CUR" ] && CUR=$(ip -d link show gre-pd 2>/dev/null | sed -n 's/.*remote \([^ ]*\).*/\1/p' | head -1 || true)
  HAS_FOU=0
  ip -d link show gre-pd 2>/dev/null | grep -q 'encap fou' && HAS_FOU=1
  WANT_FOU=0
  [ "$GRE_FOU" = 1 ] && WANT_FOU=1
  if [ "$CUR" = "$DIGI_VTEP" ] && ip link show gre-pd >/dev/null 2>&1 && [ "$HAS_FOU" = "$WANT_FOU" ]; then
    need_rebuild=0
  fi
fi

if [ "$need_rebuild" = 1 ]; then
  ip link del gre-pd 2>/dev/null || true
  ip -6 tunnel del gre-pd 2>/dev/null || true
  ip tunnel del gre-pd 2>/dev/null || true
  if [ "$GRE_FAMILY" = ip6 ]; then
    ip -6 tunnel add gre-pd mode ip6gre local "$LOCAL_VTEP" remote "$DIGI_VTEP" ttl 64 encaplimit none
  elif [ "$GRE_FOU" = 1 ]; then
    ip link add gre-pd type gre local "$LOCAL_VTEP_V4" remote "$DIGI_VTEP" ttl 64 \
      encap fou encap-sport "$FOU_PORT" encap-dport "$FOU_PORT"
  else
    ip tunnel add gre-pd mode gre local "$LOCAL_VTEP_V4" remote "$DIGI_VTEP" ttl 64
  fi
fi

ip addr replace "$INNER_LOCAL" dev gre-pd 2>/dev/null || true
ip link set gre-pd mtu "$MTU" up
ip route replace 79.172.242.0/24 via "$INNER_PEER" dev gre-pd

sysctl -q -w net.ipv4.ip_forward=1
sysctl -q -w net.ipv4.conf.all.rp_filter=0
sysctl -q -w net.ipv4.conf.default.rp_filter=0
sysctl -q -w net.ipv4.conf.gre-pd.rp_filter=0 2>/dev/null || true
iptables -C FORWARD -i gre-pd -j ACCEPT 2>/dev/null || iptables -I FORWARD -i gre-pd -j ACCEPT
iptables -C FORWARD -o gre-pd -j ACCEPT 2>/dev/null || iptables -I FORWARD -o gre-pd -j ACCEPT
iptables -C FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
  iptables -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -t nat -C POSTROUTING -s 79.172.242.0/24 -o eth0 -j MASQUERADE 2>/dev/null || \
  iptables -t nat -I POSTROUTING 1 -s 79.172.242.0/24 -o eth0 -j MASQUERADE

if [ -x /usr/local/sbin/pd-gre-harden-vps.sh ]; then
  /usr/local/sbin/pd-gre-harden-vps.sh || true
fi
echo "gre-pd ok family=$GRE_FAMILY fou=$GRE_FOU remote=$DIGI_VTEP"
