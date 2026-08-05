#!/bin/sh
# Keep Digi underlay + PD GRE alive across PPPoE flaps / VPP restarts.
# Timer: every ~60s. Egress is PD-only (no Digi sticky).
# While Digi withholds global IPv6, only keep LAN FIB — never flap PPPoE.
set -eu
VPP="/usr/bin/vppctl -s /run/vpp/cli.sock"
. /etc/pd/pd-gre.conf

$VPP show version >/dev/null 2>&1 || exit 0

DIGI_UP=0
$VPP show interface digi 2>/dev/null | grep -q ' up ' && DIGI_UP=1
PPPOE_SESS=0
$VPP show pppoe client 2>/dev/null | grep -q "PPPOE_CLIENT_SESSION" && PPPOE_SESS=1

if [ "$DIGI_UP" = 0 ] || [ "$PPPOE_SESS" = 0 ]; then
  # Only restart pppoe if truly down — not when IPv6 is merely missing
  logger -t pd-gre-watchdog "digi/pppoe down (digi_up=$DIGI_UP sess=$PPPOE_SESS) — starting vpp-pppoe-native"
  systemctl start vpp-pppoe-native.service || true
  exit 0
fi

# LAN can be prepared without Digi global IPv6
if [ -x /usr/local/sbin/pd-lan-prepare.sh ]; then
  LAN_NEED=0
  if ! $VPP show interface address loop10 2>/dev/null | grep -qE '79\.172\.242\.1/32' \
    || $VPP show ip fib table 0 79.172.242.0/24 2>/dev/null | grep -q 'ipv4-glean'; then
    LAN_NEED=1
  else
    # Catch adjacency-only /32s (forwarding UNRESOLVED → covering /24 drop blackholes PVE)
    for hip in 79.172.242.2 79.172.242.3 79.172.242.10; do
      fib=$($VPP show ip fib table 81 "${hip}/32" 2>/dev/null | tr -d '\r')
      echo "$fib" | grep -q 'CLI refs:.*contributing,active,' || LAN_NEED=1
      echo "$fib" | grep -q 'forwarding:   UNRESOLVED' && LAN_NEED=1
    done
  fi
  if [ "$LAN_NEED" = 1 ]; then
    /usr/local/sbin/pd-lan-prepare.sh >/dev/null 2>&1 || true
  fi
fi

SRC=$($VPP show pppoe client detail 2>/dev/null | sed -n 's/.*wan-ipv6 observed \([^ /]*\).*/\1/p' | tr -d '\r' | head -1)
SRC=${SRC%%/*}
case "$SRC" in
  ""|"<none>"|none)
    # Quiet wait for Digi global; do not recreate PPPoE
    exit 0 ;;
esac

OLD=$(cat /run/pd-vtep-live.txt 2>/dev/null || true)
case "$OLD" in
  ""|"<none>"|none) OLD="" ;;
esac

GRE_OK=1
$VPP show interface gre0 2>/dev/null | grep -q ' up ' || GRE_OK=0
CUR_SRC=$($VPP show gre tunnel 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
[ -n "$CUR_SRC" ] && [ "$CUR_SRC" != "$SRC" ] && GRE_OK=0

LAN_OK=1
$VPP show interface address loop10 2>/dev/null | grep -qE '79\.172\.242\.1/32' || LAN_OK=0
if $VPP show ip fib table 0 79.172.242.0/24 2>/dev/null | grep -q 'ipv4-glean'; then
  LAN_OK=0
fi
for hip in 79.172.242.2 79.172.242.3 79.172.242.10; do
  fib=$($VPP show ip fib table 81 "${hip}/32" 2>/dev/null | tr -d '\r')
  echo "$fib" | grep -q 'CLI refs:.*contributing,active,' || LAN_OK=0
  echo "$fib" | grep -q 'forwarding:   UNRESOLVED' && LAN_OK=0
done

if [ "$OLD" != "$SRC" ] || [ "$GRE_OK" = 0 ] || [ "$LAN_OK" = 0 ]; then
  logger -t pd-gre-watchdog "reactivate old=${OLD:-none} new=$SRC gre_ok=$GRE_OK lan_ok=$LAN_OK"
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
