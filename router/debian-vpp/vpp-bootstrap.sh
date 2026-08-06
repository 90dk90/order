#!/bin/sh
set -eu

VPP="/usr/bin/vppctl -s /run/vpp/cli.sock"
MODE=linux
if [ -r /etc/default/vpp-pppoe-mode ]; then
  # shellcheck disable=SC1091
  . /etc/default/vpp-pppoe-mode
  MODE="${VPP_PPPOE_MODE:-linux}"
fi

for _ in $(seq 1 60); do
  if $VPP show version >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

# PD_PPPOE=0 / MODE=disabled → leave Digi WAN down (Proximus VPP VXLAN mode)
PD_PPPOE=1
if [ -r /etc/default/pd-underlay ]; then
  # shellcheck disable=SC1091
  . /etc/default/pd-underlay
fi
if [ "${PD_PPPOE:-1}" = "0" ] || [ "$MODE" = "disabled" ]; then
  $VPP set interface state x520wan down
else
  $VPP set interface state x520wan up
fi
$VPP set interface state x520lan up
# Unused X520 ports: keep down (avoid poll tax on GRE single-RSS worker)
$VPP set interface state x520extra0 down
$VPP set interface state x520extra1 down

# tap30 always needed for Infrawire underlay host path until PD is fully in-VPP
if ! $VPP show interface | /bin/grep -q '^tap30[[:space:]]'; then
  $VPP create tap id 30 host-if-name vpp6-host host-mtu-size 1500 num-rx-queues 4 num-tx-queues 4 rx-ring-size 4096 tx-ring-size 4096
fi
$VPP set interface state tap30 up

if [ "${PD_PPPOE:-1}" = "0" ] || [ "$MODE" = "disabled" ]; then
  /usr/local/sbin/vpp-rx-placement.sh || true
  /usr/local/sbin/vpp-performance-tuning.sh || true
  /sbin/ip link set vpp6-host up 2>/dev/null || true
  exit 0
fi

if [ "$MODE" = "native" ]; then
  # Native Digi PPPoE: do NOT L2-bridge x520wan to Linux
  /usr/local/sbin/vpp-rx-placement.sh
  /usr/local/sbin/vpp-performance-tuning.sh || true
  /sbin/ip link set vpp6-host up 2>/dev/null || true
  /sbin/sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
  exit 0
fi

# Classic softpath: BD20 bridges Digi WAN to Linux pppd
if ! $VPP show interface | /bin/grep -q '^tap20[[:space:]]'; then
  $VPP create tap id 20 host-if-name vpp-pppoe host-mtu-size 1500 num-rx-queues 4 num-tx-queues 4 rx-ring-size 4096 tx-ring-size 4096
fi

$VPP set interface state tap20 up
/usr/local/sbin/vpp-rx-placement.sh
/usr/local/sbin/vpp-performance-tuning.sh || true
if ! $VPP show bridge-domain 20 detail | /bin/grep -q '^[[:space:]]*20[[:space:]]'; then
  $VPP create bridge-domain 20
fi
$VPP set interface l2 bridge x520wan 20
$VPP set interface l2 bridge tap20 20

/sbin/ip link set vpp-pppoe up
/sbin/ip link set vpp6-host up
/sbin/sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
/sbin/sysctl -w net.ipv6.conf.ppp0.accept_ra=2 >/dev/null 2>&1 || true
/usr/local/sbin/vpp-performance-tuning.sh || true
