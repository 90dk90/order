#!/bin/sh
set -eu

LOCKDIR="/run/vpp-stack-reconcile.lock"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  exit 0
fi
trap "rmdir \"$LOCKDIR\" 2>/dev/null || true" EXIT INT TERM

MODE=linux
if [ -r /etc/default/vpp-pppoe-mode ]; then
  # shellcheck disable=SC1091
  . /etc/default/vpp-pppoe-mode
  MODE="${VPP_PPPOE_MODE:-linux}"
fi

for _ in $(seq 1 60); do
  if /usr/bin/vppctl -s /run/vpp/cli.sock show version >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

/usr/local/sbin/vpp-bootstrap.sh

if [ "$MODE" = "native" ]; then
  /bin/systemctl start vpp-pppoe-native.service
  # Wait Digi LCP host iface (not linux ppp0)
  for _ in $(seq 1 90); do
    if /sbin/ip link show dev vpp-digi >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  if ! /sbin/ip link show dev vpp-digi >/dev/null 2>&1; then
    exit 0
  fi
else
  /bin/systemctl start pppoe-vpp.service
  for _ in $(seq 1 60); do
    if /sbin/ip link show dev ppp0 >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  if ! /sbin/ip link show dev ppp0 >/dev/null 2>&1; then
    exit 0
  fi
fi

/bin/systemctl start wide-dhcpv6-client.service || true
for _ in $(seq 1 60); do
  /usr/local/sbin/vpp-sync-ipv6-pd.py >/dev/null 2>&1 || true
  if [ -r /run/vpp-tap30-ipv6.env ]; then
    break
  fi
  sleep 1
done
if [ ! -r /run/vpp-tap30-ipv6.env ]; then
  # Without Digi PD, keep clients online via Digi SNAT
  /usr/local/sbin/digi-snat-fallback.sh >/dev/null 2>&1 || true
  exit 0
fi

/bin/systemctl restart vpp-vxlan.service || true
/bin/systemctl restart infrawire-gre.service || true
/bin/systemctl restart bird.service || true
/usr/local/sbin/vpp-rx-placement.sh >/dev/null 2>&1 || true
/usr/local/sbin/vpp-performance-tuning.sh >/dev/null 2>&1 || true
/usr/local/sbin/vpp-mss-clamp.sh >/dev/null 2>&1 || true

# If GRE peer is down, keep clients online via Digi SNAT
if ! ping -c 1 -W 2 172.16.206.1 >/dev/null 2>&1; then
  /usr/local/sbin/digi-snat-fallback.sh >/dev/null 2>&1 || true
fi
