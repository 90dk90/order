#!/bin/sh
# Watchdog for Linux GRE (Proximus primary). Prefer soft repair over GRE rebuild.
set -eu
. /etc/pd/pd-gre.conf

INNER_PEER="${INNER_PEER:-172.16.207.1}"
GRE_NAME="${GRE_NAME:-gre-pd}"
EXIT_TAP="${EXIT_TAP:-vpp6-host}"

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

gre_bad=0
ip link show "$GRE_NAME" >/dev/null 2>&1 || gre_bad=1
if [ "$gre_bad" = 0 ]; then
  if ! ping -c 1 -W 2 "$INNER_PEER" >/dev/null 2>&1; then
    sleep 1
    ping -c 2 -W 2 "$INNER_PEER" >/dev/null 2>&1 || gre_bad=1
  fi
fi

exit_bad=0
if [ "${PD_ENABLE_EXIT_TAP:-1}" = 1 ]; then
  ip link show "$EXIT_TAP" >/dev/null 2>&1 || exit_bad=1
  ip -4 addr show "$EXIT_TAP" 2>/dev/null | grep -q '10.254.207.2' || exit_bad=1
  ping -c 1 -W 2 79.172.242.1 >/dev/null 2>&1 || exit_bad=1
fi

if [ "$gre_bad" = 1 ] || [ "$exit_bad" = 1 ]; then
  logger -t pd-gre-watchdog "repair gre_bad=$gre_bad exit_bad=$exit_bad"
  /usr/local/sbin/pd-linux-gre-activate.sh || true
fi
