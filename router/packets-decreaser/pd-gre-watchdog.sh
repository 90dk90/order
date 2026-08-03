#!/bin/sh
set -eu
VPP="/usr/bin/vppctl -s /run/vpp/cli.sock"
. /etc/pd/pd-gre.conf
$VPP show version >/dev/null 2>&1 || exit 0
# Digi must be up
$VPP show interface digi 2>/dev/null | grep -q ' up ' || exit 0
SRC=$($VPP show interface addr digi 2>/dev/null | awk '/L3 2a01:/{gsub(/\/.*/,"",$2); print $2; exit}')
[ -n "$SRC" ] || exit 0
OLD=$(cat /run/pd-vtep-live.txt 2>/dev/null || true)
GRE_OK=1
$VPP show interface gre0 2>/dev/null | grep -q ' up ' || GRE_OK=0
# ping peer cheaply via vpp every few runs? keep light
if [ "$OLD" != "$SRC" ] || [ "$GRE_OK" = 0 ]; then
  logger -t pd-gre-watchdog "VTEP change or gre down old=$OLD new=$SRC gre_ok=$GRE_OK — reactivating"
  PD_FORCE_SYNC=1 /usr/local/sbin/pd-gre-activate.sh
  exit 0
fi
# Health: if gre peer not answering, force VPS sync
if ! $VPP ping "$INNER_PEER" repeat 1 2>/dev/null | grep -q 'received, 0% packet loss'; then
  # one more try
  sleep 1
  if ! $VPP ping "$INNER_PEER" repeat 2 2>/dev/null | grep -q 'received'; then
    logger -t pd-gre-watchdog "GRE peer unreachable — force sync"
    PD_FORCE_SYNC=1 /usr/local/sbin/pd-gre-activate.sh || true
  fi
fi
