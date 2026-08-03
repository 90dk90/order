#!/bin/sh
# Digi PPPoE client inside VPP (no Linux pppd / tap20 hairpin).
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

# Recreate client
if $VPP show pppoe client 2>/dev/null | grep -q .; then
  $VPP create pppoe client "$IFACE" host-uniq 1 del 2>/dev/null || true
fi
$VPP create pppoe client "$IFACE" host-uniq 1 name "$NAME"
$VPP set pppoe client "$NAME" username "$USER_NAME" password "$PASSWORD" \
  mtu 1492 mru 1492 use-peer-dns add-default-route

for i in $(seq 1 90); do
  if $VPP show pppoe client 2>/dev/null | grep -q "PPPOE_CLIENT_SESSION"; then
    break
  fi
  sleep 1
done

# LCP for optional Linux DHCPv6 control-plane (tun)
if ! $VPP show lcp 2>/dev/null | grep -q "[[:space:]]vpp-digi\\>"; then
  $VPP lcp create "$NAME" host-if vpp-digi tun >/dev/null 2>&1 || true
fi
ip link set vpp-digi up 2>/dev/null || true
sysctl -w net.ipv6.conf.vpp-digi.forwarding=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.vpp-digi.accept_ra=2 >/dev/null 2>&1 || true

# Best-effort in-VPP DHCPv6 (needs dhcp runtime symbols for full PD observability)
$VPP dhcp6 client "$NAME" 2>/dev/null || true
$VPP dhcp6 pd client "$NAME" prefix group digi-pd 2>/dev/null || true

# NAT44: client LAN -> Digi CGNAT
$VPP nat44 plugin enable 2>/dev/null || true
$VPP set interface nat44 in loop10 out "$NAME" 2>/dev/null || true
$VPP set interface nat44 in x520lan out "$NAME" 2>/dev/null || true
# Pool is the Digi IPv4; ignore failure if already present
DIGI_IP4=$($VPP show interface addr "$NAME" 2>/dev/null | sed -n 's/.*L3 \([0-9.]*\)\/32.*/\1/p' | head -1)
if [ -n "$DIGI_IP4" ]; then
  $VPP nat44 add address "$DIGI_IP4" 2>/dev/null || true
fi

# Prefer Digi default; drop temporary SNAT hairpin default
$VPP ip route del 0.0.0.0/0 via 10.254.254.2 tap50 2>/dev/null || true
rm -f /run/vpp-prefer-digi-snat

$VPP show pppoe client || true
$VPP show interface addr "$NAME" || true
