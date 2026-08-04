#!/bin/sh
# Keep Digi underlay + VPP-classify sticky alive across PPPoE flaps / VPP restarts.
# Timer: every ~60s. Always VPP path (digi-sticky-outbound.sh mode=vpp-classify).
set -eu
VPP="/usr/bin/vppctl -s /run/vpp/cli.sock"
. /etc/pd/pd-gre.conf

$VPP show version >/dev/null 2>&1 || exit 0

# After VPP crash/restart, BindsTo drops vpp-pppoe-native to inactive — bring it back.
DIGI_UP=0
$VPP show interface digi 2>/dev/null | grep -q ' up ' && DIGI_UP=1
PPPOE_SESS=0
$VPP show pppoe client 2>/dev/null | grep -q "PPPOE_CLIENT_SESSION" && PPPOE_SESS=1

if [ "$DIGI_UP" = 0 ] || [ "$PPPOE_SESS" = 0 ]; then
  logger -t pd-gre-watchdog "digi/pppoe down (digi_up=$DIGI_UP sess=$PPPOE_SESS) — starting vpp-pppoe-native"
  systemctl start vpp-pppoe-native.service || true
  # ExecStartPost already runs pd-gre-activate (+ sticky if /etc/pd/sticky-digi)
  exit 0
fi

SRC=$($VPP show pppoe client detail 2>/dev/null | sed -n 's/.*wan-ipv6 observed \([^ /]*\).*/\1/p' | tr -d '\r' | head -1)
[ -n "$SRC" ] || exit 0
OLD=$(cat /run/pd-vtep-live.txt 2>/dev/null || true)
GRE_OK=1
$VPP show interface gre0 2>/dev/null | grep -q ' up ' || GRE_OK=0
CUR_SRC=$($VPP show gre tunnel 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
[ -n "$CUR_SRC" ] && [ "$CUR_SRC" != "$SRC" ] && GRE_OK=0

# Sticky must stay on loop10 after any underlay rebuild
STICKY_OK=1
if [ -f /etc/pd/sticky-digi ]; then
  MODE=$(sed -n 's/^mode=//p' /etc/pd/sticky-digi 2>/dev/null | head -1)
  if [ "$MODE" = "vpp-classify" ] || [ "$MODE" = "vpp-abf-hairpin" ]; then
    $VPP show interface features loop10 2>/dev/null | grep -q ip4-inacl || STICKY_OK=0
    # Accept /32 (preferred) or legacy /24 — never force /24 (ARP storm)
    $VPP show interface address loop10 2>/dev/null | grep -qE '79\.172\.242\.1/(32|24)' || STICKY_OK=0
    # Regress if table 0 still gleams the /24 (causes LAN ARP flood)
    if $VPP show ip fib table 0 79.172.242.0/24 2>/dev/null | grep -q 'ipv4-glean'; then
      STICKY_OK=0
    fi
  fi
fi

if [ "$OLD" != "$SRC" ] || [ "$GRE_OK" = 0 ] || [ "$STICKY_OK" = 0 ]; then
  logger -t pd-gre-watchdog "reactivate old=$OLD new=$SRC gre_ok=$GRE_OK sticky_ok=$STICKY_OK"
  PD_FORCE_SYNC=1 /usr/local/sbin/pd-gre-activate.sh
  exit 0
fi

if ! $VPP ping "$INNER_PEER" repeat 1 2>/dev/null | grep -q 'received, 0% packet loss'; then
  sleep 1
  if ! $VPP ping "$INNER_PEER" repeat 2 2>/dev/null | grep -q 'received'; then
    logger -t pd-gre-watchdog "GRE peer unreachable — force sync"
    PD_FORCE_SYNC=1 /usr/local/sbin/pd-gre-activate.sh || true
  fi
fi
