#!/bin/sh
# Digi router: hide WAN VTEP + tunnel internals from casual discovery.
# VPP 26.x CLI: set acl-plugin interface <if> input acl <idx>
# Prefer in-place replace of ACL index from /run/pd-digi-wan-acl.idx (default 0).
set -eu
. /etc/pd/pd-gre.conf
VPP="/usr/bin/vppctl -s /run/vpp/cli.sock"

DIGI_IF="${DIGI_IF:-digi}"
PD_VTEP="${PD_VTEP:?PD_VTEP required}"
TAG="pd-digi-wan"
ACL_IDX_FILE=/run/pd-digi-wan-acl.idx

pick_digi_vtep() {
  obs=$($VPP show pppoe client detail 2>/dev/null | sed -n 's/.*wan-ipv6 observed \([^ /]*\).*/\1/p' | tr -d '\r' | head -1)
  if [ -n "$obs" ]; then
    printf '%s\n' "$obs"
    return 0
  fi
  if [ -r /run/pd-vtep-live.txt ]; then
    head -1 /run/pd-vtep-live.txt
    return 0
  fi
  $VPP show interface addr "$DIGI_IF" 2>/dev/null | awk '
    /L3 2a01:4700:807f:/{gsub(/\/.*/,"",$2); print $2; exit}
  '
}

SRC=$(pick_digi_vtep)
[ -n "$SRC" ] || { echo "pd-gre-harden: no Digi VTEP yet"; exit 1; }
$VPP show version >/dev/null 2>&1 || { echo "pd-gre-harden: vpp down"; exit 1; }
$VPP show interface "$DIGI_IF" >/dev/null 2>&1 || { echo "pd-gre-harden: $DIGI_IF missing"; exit 1; }

IDX=0
if [ -r "$ACL_IDX_FILE" ]; then
  IDX=$(tr -dc '0-9' < "$ACL_IDX_FILE")
fi
[ -n "$IDX" ] || IDX=0

# sport on proto 58 = ICMPv6 type (echo-request=128).
$VPP set acl-plugin acl index "$IDX" tag "$TAG" \
  permit src fe80::/10 dst ::/0, \
  permit src ::/0 dst fe80::/10, \
  permit src "$PD_VTEP/128" dst "$SRC/128" proto 47, \
  permit src "$PD_VTEP/128" dst "$SRC/128" proto 58, \
  deny src ::/0 dst "$SRC/128" proto 47, \
  deny src ::/0 dst "$SRC/128" proto 58 sport 128-128, \
  deny src ::/0 dst "$SRC/128" proto 6, \
  deny src ::/0 dst "$SRC/128" proto 17, \
  permit src ::/0 dst ::/0

# Ensure attached (idempotent)
$VPP set acl-plugin interface "$DIGI_IF" input acl "$IDX" del 2>/dev/null || true
$VPP set acl-plugin interface "$DIGI_IF" input acl "$IDX"
echo "$IDX" > "$ACL_IDX_FILE"

# No global IPv6 on LAN BVI / NICs
for iface in loop10 x520lan x520extra0 x520extra1; do
  for old in $($VPP show interface addr "$iface" 2>/dev/null | sed -n 's/.*L3 \([^ ]*\).*/\1/p'); do
    case "$old" in
      *:*) $VPP set interface ip address del "$iface" "$old" 2>/dev/null || true ;;
    esac
  done
done

# Linux LCP (vpp-digi)
if ip link show vpp-digi >/dev/null 2>&1; then
  sysctl -q -w net.ipv6.conf.vpp-digi.accept_ra=0 || true
  sysctl -q -w net.ipv6.conf.vpp-digi.autoconf=0 || true
  sysctl -q -w net.ipv6.conf.vpp-digi.forwarding=0 || true
  for a in $(ip -6 -o addr show dev vpp-digi scope global 2>/dev/null | awk '{print $4}'); do
    ip -6 addr del "$a" dev vpp-digi 2>/dev/null || true
  done
  if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -N PD_DIGI_WAN 2>/dev/null || ip6tables -F PD_DIGI_WAN
    ip6tables -F PD_DIGI_WAN
    ip6tables -A PD_DIGI_WAN -s "$PD_VTEP/128" -j ACCEPT
    ip6tables -A PD_DIGI_WAN -p ipv6-icmp --icmpv6-type echo-request -d "$SRC/128" -j DROP
    ip6tables -A PD_DIGI_WAN -p 47 -d "$SRC/128" -j DROP
    ip6tables -A PD_DIGI_WAN -p tcp -d "$SRC/128" -j DROP
    ip6tables -A PD_DIGI_WAN -p udp -d "$SRC/128" -j DROP
    ip6tables -C INPUT -i vpp-digi -j PD_DIGI_WAN 2>/dev/null || \
      ip6tables -I INPUT -i vpp-digi -j PD_DIGI_WAN
  fi
fi

for iface in vpp6-host x520lan; do
  ip link show "$iface" >/dev/null 2>&1 || continue
  sysctl -q -w "net.ipv6.conf.${iface}.disable_ipv6=1" 2>/dev/null || \
    sysctl -q -w "net.ipv6.conf.${iface}.accept_ra=0" 2>/dev/null || true
  sysctl -q -w "net.ipv6.conf.${iface}.autoconf=0" 2>/dev/null || true
done

if command -v iptables >/dev/null 2>&1; then
  INNER_IP=$(printf '%s\n' "${INNER_LOCAL:-172.16.207.2/30}" | cut -d/ -f1)
  for src in "$INNER_IP" 79.172.242.1; do
    iptables -C OUTPUT -p icmp --icmp-type time-exceeded -s "$src" -j DROP 2>/dev/null || \
      iptables -I OUTPUT -p icmp --icmp-type time-exceeded -s "$src" -j DROP
    iptables -C OUTPUT -p icmp --icmp-type destination-unreachable -s "$src" -j DROP 2>/dev/null || \
      iptables -I OUTPUT -p icmp --icmp-type destination-unreachable -s "$src" -j DROP
  done
fi

printf '%s\n' "$SRC" > /run/pd-harden-vtep.txt
echo "pd-gre-harden ok digi=$SRC pd=$PD_VTEP acl=$IDX"
