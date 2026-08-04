#!/bin/sh
# Digi router: hide WAN VTEP + tunnel internals from casual discovery.
# - VPP ACL on digi: GRE/ICMPv6 from PD VTEP only toward Digi global IPv6
# - drop echo-request / foreign GRE to Digi WAN
# - no global IPv6 on LAN BD / loop10
# - silence ICMP time-exceeded / unreachable from gre0 + loop10 (best-effort)
# - Linux ip6tables on vpp-digi LCP as belt-and-suspenders
set -eu
. /etc/pd/pd-gre.conf
VPP="/usr/bin/vppctl -s /run/vpp/cli.sock"

DIGI_IF="${DIGI_IF:-digi}"
PD_VTEP="${PD_VTEP:?PD_VTEP required}"
TAG="pd-digi-wan"

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

# --- VPP ACL on digi (input) ---
# Replace previous tagged ACL if present.
OLD_IDX=$($VPP show acl-plugin acl 2>/dev/null | awk -v t="$TAG" '
  /^acl-index/ { idx=$2; gsub(/:/,"",idx) }
  index($0,t) { print idx; exit }
')
if [ -n "${OLD_IDX:-}" ]; then
  $VPP set interface input acl intfc "$DIGI_IF" ip6 del "$OLD_IDX" 2>/dev/null || true
  $VPP set acl-plugin interface "$DIGI_IF" del 2>/dev/null || true
  $VPP set acl-plugin acl del "$OLD_IDX" 2>/dev/null || true
fi

# sport on proto 58 = ICMPv6 type (echo-request=128).
# Keep link-local PPP control; allow GRE+ICMPv6 only from PD to Digi global;
# deny foreign GRE and echo-request to Digi global; permit the rest (PMTUD etc. toward others).
$VPP set acl-plugin acl tag "$TAG" \
  permit src fe80::/10 dst ::/0, \
  permit src ::/0 dst fe80::/10, \
  permit src "$PD_VTEP/128" dst "$SRC/128" proto 47, \
  permit src "$PD_VTEP/128" dst "$SRC/128" proto 58, \
  deny src ::/0 dst "$SRC/128" proto 47, \
  deny src ::/0 dst "$SRC/128" proto 58 sport 128-128, \
  deny src ::/0 dst "$SRC/128" proto 6, \
  deny src ::/0 dst "$SRC/128" proto 17, \
  permit src ::/0 dst ::/0 \
  >/tmp/pd-acl-set.out 2>&1 || true

NEW_IDX=$($VPP show acl-plugin acl 2>/dev/null | awk -v t="$TAG" '
  /^acl-index/ { idx=$2; gsub(/:/,"",idx) }
  index($0,t) { print idx; exit }
')
if [ -z "${NEW_IDX:-}" ]; then
  NEW_IDX=$(awk "/acl-index|ACL/ {for(i=1;i<=NF;i++) if(\$i ~ /^[0-9]+\$/){print \$i; exit}}" /tmp/pd-acl-set.out 2>/dev/null || true)
fi
if [ -n "${NEW_IDX:-}" ]; then
  $VPP set interface input acl intfc "$DIGI_IF" ip6 "$NEW_IDX" 2>/dev/null \
    || $VPP set acl-plugin interface "$DIGI_IF" input acl "$NEW_IDX" 2>/dev/null \
    || $VPP set interface acl input acl "$NEW_IDX" ip6 intfc "$DIGI_IF" 2>/dev/null \
    || true
  echo "$NEW_IDX" > /run/pd-digi-wan-acl.idx
else
  echo "pd-gre-harden: warning: could not resolve ACL index" >&2
  cat /tmp/pd-acl-set.out 2>/dev/null || true
fi

# --- No global IPv6 on LAN BVI / NICs ---
for iface in loop10 x520lan x520extra0 x520extra1; do
  for old in $($VPP show interface addr "$iface" 2>/dev/null | sed -n 's/.*L3 \([^ ]*\).*/\1/p'); do
    case "$old" in
      *:*) $VPP set interface ip address del "$iface" "$old" 2>/dev/null || true ;;
    esac
  done
done

# --- Linux LCP (vpp-digi): belt-and-suspenders ---
if ip link show vpp-digi >/dev/null 2>&1; then
  sysctl -q -w net.ipv6.conf.vpp-digi.accept_ra=0 || true
  sysctl -q -w net.ipv6.conf.vpp-digi.autoconf=0 || true
  sysctl -q -w net.ipv6.conf.vpp-digi.forwarding=0 || true
  # Strip any global IPv6 accidentally mirrored onto LCP
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

# LAN-facing Linux taps: no IPv6 advertise / autoconf
for iface in vpp6-host x520lan; do
  ip link show "$iface" >/dev/null 2>&1 || continue
  sysctl -q -w "net.ipv6.conf.${iface}.disable_ipv6=1" 2>/dev/null || \
    sysctl -q -w "net.ipv6.conf.${iface}.accept_ra=0" 2>/dev/null || true
  sysctl -q -w "net.ipv6.conf.${iface}.autoconf=0" 2>/dev/null || true
done

# Silence ICMP time-exceeded sourced from GRE inner / GW if Linux ever sees them
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
echo "pd-gre-harden ok digi=$SRC pd=$PD_VTEP acl=${NEW_IDX:-unknown}"
