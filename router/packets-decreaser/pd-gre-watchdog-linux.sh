#!/bin/sh
# Watchdog for Linux GRE (Proximus primary / Digi backup). No VPP GRE.
# Does not flap Digi PPPoE while IPv6 is missing.
set -eu
. /etc/pd/pd-gre.conf

INNER_PEER="${INNER_PEER:-172.16.207.1}"
GRE_NAME="${GRE_NAME:-gre-pd}"

# Digi Linux PPPoE: restart only if ppp0 truly down
if ! ip link show ppp0 >/dev/null 2>&1 || ! ip -4 addr show ppp0 2>/dev/null | grep -q 'inet '; then
  if systemctl is-enabled pppoe-vpp.service >/dev/null 2>&1; then
    logger -t pd-gre-watchdog "ppp0 down — restart pppoe-vpp"
    systemctl start pppoe-vpp.service || true
  fi
fi

# LAN anti-ARP always safe
if [ -x /usr/local/sbin/pd-lan-prepare.sh ]; then
  /usr/local/sbin/pd-lan-prepare.sh >/dev/null 2>&1 || true
fi

need=0
ip link show "$GRE_NAME" >/dev/null 2>&1 || need=1
if [ "$need" = 0 ]; then
  if ! ping -c 1 -W 2 "$INNER_PEER" >/dev/null 2>&1; then
    sleep 1
    ping -c 2 -W 2 "$INNER_PEER" >/dev/null 2>&1 || need=1
  fi
fi

if [ "$need" = 1 ] && [ -x /usr/local/sbin/pd-linux-gre-activate.sh ]; then
  logger -t pd-gre-watchdog "linux GRE recreate/sync"
  /usr/local/sbin/pd-linux-gre-activate.sh || true
fi
