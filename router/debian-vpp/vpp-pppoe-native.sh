#!/bin/sh
# Digi PPPoE client inside VPP (no Linux pppd / tap20 hairpin).
# Idempotent: never tear down a live session just to "refresh".
set -eu
VPP="/usr/bin/vppctl -s /run/vpp/cli.sock"

if [ -r /etc/default/vpp-pppoe-native ]; then
  # shellcheck disable=SC1091
  . /etc/default/vpp-pppoe-native
fi

USER_NAME="${DIGI_PPPOE_USER:-BR488394}"
PASSWORD="${DIGI_PPPOE_PASS:-3A41336D7B}"
IFACE="${DIGI_PPPOE_IFACE:-x520wan}"
NAME="${DIGI_PPPOE_NAME:-digi}"

for _ in $(seq 1 60); do
  if $VPP show version >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! $VPP show plugins 2>/dev/null | grep -q pppoeclient_plugin; then
  echo "pppoeclient_plugin not loaded" >&2
  exit 1
fi

# Ensure WAN is not in an L2 bridge (BD20 leftover)
$VPP create bridge-domain 20 del 2>/dev/null || true
$VPP set interface state "$IFACE" up

SESSION_UP=0
if $VPP show pppoe client 2>/dev/null | grep -q "PPPOE_CLIENT_SESSION"; then
  DIGI_IP4=$($VPP show pppoe client detail 2>/dev/null | sed -n 's/.*ipv4 local \([0-9.]*\) peer.*/\1/p' | tr -d '\r' | head -1)
  if [ -n "$DIGI_IP4" ] && [ "$DIGI_IP4" != "0.0.0.0" ]; then
    SESSION_UP=1
  fi
fi

if [ "$SESSION_UP" -eq 0 ]; then
  # Only recreate when there is no live Digi IPv4 session
  if $VPP show pppoe client 2>/dev/null | grep -q .; then
    $VPP create pppoe client "$IFACE" host-uniq 1 del 2>/dev/null || true
    sleep 2
  fi
  # Clear leftover addresses from a previous digi instance if still present
  for old in $($VPP show interface addr "$NAME" 2>/dev/null | sed -n 's/.*L3 \([^ ]*\).*/\1/p'); do
    $VPP set interface ip address del "$NAME" "$old" 2>/dev/null || true
  done
  $VPP create pppoe client "$IFACE" host-uniq 1 name "$NAME"
  $VPP set pppoe client "$NAME" username "$USER_NAME" password "$PASSWORD" \
    mtu 1492 mru 1492 use-peer-dns add-default-route

  for i in $(seq 1 90); do
    if $VPP show pppoe client 2>/dev/null | grep -q "PPPOE_CLIENT_SESSION"; then
      DIGI_IP4=$($VPP show pppoe client detail 2>/dev/null | sed -n 's/.*ipv4 local \([0-9.]*\) peer.*/\1/p' | tr -d '\r' | head -1)
      if [ -n "$DIGI_IP4" ] && [ "$DIGI_IP4" != "0.0.0.0" ]; then
        break
      fi
    fi
    sleep 1
  done
else
  # Do NOT call `set pppoe client` on a live session — it can force rediscovery.
  :
fi

# LCP for Linux DHCPv6 control-plane (tun). Do not recreate if present.
if ! $VPP show lcp 2>/dev/null | grep -q "[[:space:]]vpp-digi\\>"; then
  $VPP lcp create "$NAME" host-if vpp-digi tun >/dev/null 2>&1 || true
fi
ip link set vpp-digi up 2>/dev/null || true
ip link set vpp-digi mtu 1492 2>/dev/null || true
sysctl -w net.ipv6.conf.vpp-digi.forwarding=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.vpp-digi.accept_ra=0 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.vpp-digi.autoconf=0 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.vpp-digi.use_tempaddr=0 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.vpp-digi.addr_gen_mode=1 >/dev/null 2>&1 || true

# Align Linux LCP link-local to IPv6CP local (Digi keys off PPP LL)
LL_LOCAL=$($VPP show pppoe client detail 2>/dev/null | sed -n 's/.*ipv6cp-link-local local \([^ ]*\) peer.*/\1/p' | tr -d '\r' | head -1)
LL_PEER=$($VPP show pppoe client detail 2>/dev/null | sed -n 's/.*ipv6cp-link-local local [^ ]* peer \([^ ]*\).*/\1/p' | tr -d '\r' | head -1)
if [ -n "$LL_LOCAL" ] && [ "$LL_LOCAL" != "::" ]; then
  ip -6 addr flush dev vpp-digi 2>/dev/null || true
  ip -6 addr add "${LL_LOCAL}/128" dev vpp-digi 2>/dev/null || true
  if [ -n "$LL_PEER" ] && [ "$LL_PEER" != "::" ]; then
    ip -6 route replace "${LL_PEER}/128" dev vpp-digi 2>/dev/null || true
  fi
fi

# Digi WAN IPv6 comes from pppoeclient "wan-ipv6 observed" (e.g. 807f/...).
# Do NOT install synthetic 2a01:4700:80ff:... — outbound works, inbound from PD/Internet does not.
DIGI_IP4=$($VPP show pppoe client detail 2>/dev/null | sed -n 's/.*ipv4 local \([0-9.]*\) peer.*/\1/p' | tr -d '\r' | head -1)
if [ -n "$DIGI_IP4" ] && [ "$DIGI_IP4" != "0.0.0.0" ]; then
  for old in $($VPP show interface addr "$NAME" 2>/dev/null | sed -n 's/.*L3 \([0-9.]*\/32\).*/\1/p'); do
    case "$old" in
      "$DIGI_IP4"/32) ;;
      *) $VPP set interface ip address del "$NAME" "$old" 2>/dev/null || true ;;
    esac
  done
  for old in $($VPP show interface addr "$NAME" 2>/dev/null | sed -n 's/.*L3 \(2a01:4700:80ff:[^ ]*\).*/\1/p'); do
    $VPP set interface ip address del "$NAME" "$old" 2>/dev/null || true
  done
  $VPP ip route del ::/0 2>/dev/null || true
  $VPP ip route add ::/0 via fe80::1 "$NAME" 2>/dev/null || true
fi

# Best-effort in-VPP DHCPv6 (PD optional; GRE uses Digi-observed WAN IPv6)
$VPP dhcp6 client "$NAME" 2>/dev/null || true
$VPP dhcp6 pd client "$NAME" prefix group digi-pd 2>/dev/null || true

# Digi NAT44 only when explicitly falling back to CGNAT exit.
# PD GRE primary path must keep public 79.172.242.0/24 (no Digi SNAT).
$VPP ip route del 0.0.0.0/0 via 10.254.254.2 tap50 2>/dev/null || true
if [ -e /run/vpp-prefer-digi-snat ]; then
  $VPP nat44 plugin enable 2>/dev/null || true
  $VPP set interface nat44 in loop10 out "$NAME" 2>/dev/null || true
  $VPP set interface nat44 in x520lan out "$NAME" 2>/dev/null || true
  if [ -n "$DIGI_IP4" ]; then
    $VPP nat44 add address "$DIGI_IP4" 2>/dev/null || true
  fi
else
  $VPP set interface nat44 in loop10 out "$NAME" del 2>/dev/null || true
  $VPP set interface nat44 in x520lan out "$NAME" del 2>/dev/null || true
  if [ -n "$DIGI_IP4" ]; then
    $VPP nat44 add address "$DIGI_IP4" del 2>/dev/null || true
  fi
  $VPP clear nat44 ed sessions 2>/dev/null || true
  $VPP nat44 plugin disable 2>/dev/null || true
fi


$VPP show pppoe client || true
$VPP show interface addr "$NAME" || true
$VPP show pppoe client detail 2>/dev/null | sed -n '1,20p' || true
