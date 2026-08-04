#!/bin/sh
# Digi: hide WAN VTEP from casual ping/traceroute (ICMPv6 only — no heavy ACL).
# - Input: drop ICMPv6 echo-request to Digi global (keep GRE + LL + IPv4)
# - Output: drop ICMPv6 time-exceeded / dest-unreachable from Digi path
# - Linux: same for LCP/host-generated ICMP
set -eu
. /etc/pd/pd-gre.conf
VPP="/usr/bin/vppctl -s /run/vpp/cli.sock"

DIGI_IF="${DIGI_IF:-digi}"
PD_VTEP="${PD_VTEP:?PD_VTEP required}"
TAG="pd-digi-icmp"
IN_IDX_FILE=/run/pd-digi-wan-acl.idx
OUT_IDX_FILE=/run/pd-digi-wan-acl-out.idx

pick_digi_vtep() {
  obs=$($VPP show pppoe client detail 2>/dev/null | sed -n 's/.*wan-ipv6 observed \([^ /]*\).*/\1/p' | tr -d '\r' | head -1)
  case "$obs" in
    ""|"<none>"|none|2a01:4700:80ff:*) obs="" ;;
  esac
  if [ -n "$obs" ]; then
    printf '%s\n' "$obs"
    return 0
  fi
  # Only use interface L3 (must actually be present) — ignore stale /run files
  $VPP show interface addr "$DIGI_IF" 2>/dev/null | awk '
    /L3 2a01:4700:80ff:/{next}
    /L3 2a01:4700:/{gsub(/\/.*/,"",$2); print $2; exit}
  '
}

SRC=$(pick_digi_vtep)
[ -n "$SRC" ] || { echo "pd-gre-harden: no Digi VTEP yet"; exit 0; }
$VPP show version >/dev/null 2>&1 || { echo "pd-gre-harden: vpp down"; exit 0; }
$VPP show interface "$DIGI_IF" >/dev/null 2>&1 || { echo "pd-gre-harden: $DIGI_IF missing"; exit 0; }

IN_IDX=0
if [ -r "$IN_IDX_FILE" ]; then
  IN_IDX=$(tr -dc '0-9' < "$IN_IDX_FILE")
fi
[ -n "$IN_IDX" ] || IN_IDX=0

# proto 58 = ICMPv6; "sport" = ICMP type (echo-request=128).
# Keep IPv4 fully open (PPPoE CGNAT). Keep link-local. Allow GRE from PD.
# Do NOT blanket-deny TCP/UDP/GRE (previous heavy ACL + recreate → SIGSEGV risk).
$VPP set acl-plugin acl index "$IN_IDX" tag "${TAG}-in" \
  permit src 0.0.0.0/0 dst 0.0.0.0/0, \
  permit src fe80::/10 dst ::/0, \
  permit src ::/0 dst fe80::/10, \
  permit src "$PD_VTEP/128" dst "$SRC/128" proto 47, \
  permit src "$PD_VTEP/128" dst "$SRC/128" proto 58, \
  deny src ::/0 dst "$SRC/128" proto 58 sport 128-128, \
  permit src ::/0 dst ::/0

$VPP set acl-plugin interface "$DIGI_IF" input acl "$IN_IDX" del 2>/dev/null || true
$VPP set acl-plugin interface "$DIGI_IF" input acl "$IN_IDX"
echo "$IN_IDX" > "$IN_IDX_FILE"

# Output: hide traceroute hops (ICMPv6 type 3=time-exceeded, 1=dest-unreach)
OUT_IDX=1
if [ -r "$OUT_IDX_FILE" ]; then
  OUT_IDX=$(tr -dc '0-9' < "$OUT_IDX_FILE")
fi
[ -n "$OUT_IDX" ] || OUT_IDX=1
if [ "$OUT_IDX" = "$IN_IDX" ]; then
  OUT_IDX=$((IN_IDX + 1))
fi

$VPP set acl-plugin acl index "$OUT_IDX" tag "${TAG}-out" \
  permit src 0.0.0.0/0 dst 0.0.0.0/0, \
  deny src ::/0 dst ::/0 proto 58 sport 3-3, \
  deny src ::/0 dst ::/0 proto 58 sport 1-1, \
  permit src ::/0 dst ::/0 2>/dev/null || true

if $VPP set acl-plugin interface "$DIGI_IF" output acl "$OUT_IDX" del 2>/dev/null; then
  true
fi
$VPP set acl-plugin interface "$DIGI_IF" output acl "$OUT_IDX" 2>/dev/null || true
echo "$OUT_IDX" > "$OUT_IDX_FILE"

# No global IPv6 on LAN (underlay must not appear on BD10)
for iface in loop10 x520lan x520extra0 x520extra1; do
  for old in $($VPP show interface addr "$iface" 2>/dev/null | sed -n 's/.*L3 \([^ ]*\).*/\1/p'); do
    case "$old" in
      *:*) $VPP set interface ip address del "$iface" "$old" 2>/dev/null || true ;;
    esac
  done
done

# Linux LCP path (if present)
if ip link show vpp-digi >/dev/null 2>&1 && command -v ip6tables >/dev/null 2>&1; then
  ip6tables -N PD_DIGI_ICMP 2>/dev/null || ip6tables -F PD_DIGI_ICMP
  ip6tables -F PD_DIGI_ICMP
  ip6tables -A PD_DIGI_ICMP -s "$PD_VTEP/128" -j ACCEPT
  ip6tables -A PD_DIGI_ICMP -p ipv6-icmp --icmpv6-type echo-request -d "$SRC/128" -j DROP
  ip6tables -A PD_DIGI_ICMP -p ipv6-icmp --icmpv6-type time-exceeded -j DROP
  ip6tables -A PD_DIGI_ICMP -p ipv6-icmp --icmpv6-type destination-unreachable -j DROP
  ip6tables -C INPUT -i vpp-digi -j PD_DIGI_ICMP 2>/dev/null || \
    ip6tables -I INPUT -i vpp-digi -j PD_DIGI_ICMP
  ip6tables -C OUTPUT -p ipv6-icmp --icmpv6-type time-exceeded -j DROP 2>/dev/null || \
    ip6tables -I OUTPUT -p ipv6-icmp --icmpv6-type time-exceeded -j DROP
  ip6tables -C OUTPUT -p ipv6-icmp --icmpv6-type destination-unreachable -j DROP 2>/dev/null || \
    ip6tables -I OUTPUT -p ipv6-icmp --icmpv6-type destination-unreachable -j DROP
fi

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
echo "pd-gre-harden ok digi=$SRC pd=$PD_VTEP mode=icmp-only in=$IN_IDX out=$OUT_IDX"
