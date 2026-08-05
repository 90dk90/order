#!/bin/sh
# Move Digi PPPoE off native VPP pppoeclient onto Linux pppd (TAP vpp-pppoe).
# Avoids VPP GRE/classify crash surface on the Digi path. Idempotent.
set -eu
VPP="/usr/bin/vppctl -s /run/vpp/cli.sock"

echo "pd-digi-linux: stopping native Digi PPPoE"
systemctl stop vpp-pppoe-native.service 2>/dev/null || true
systemctl disable vpp-pppoe-native.service 2>/dev/null || true
# Drop-in that runs VPP GRE activate — not used in Linux-GRE mode
if [ -f /etc/systemd/system/vpp-pppoe-native.service.d/pd-gre.conf ]; then
  mv /etc/systemd/system/vpp-pppoe-native.service.d/pd-gre.conf \
     /etc/systemd/system/vpp-pppoe-native.service.d/pd-gre.conf.off 2>/dev/null || true
fi

$VPP create pppoe client x520wan host-uniq 1 del 2>/dev/null || true
$VPP create pppoe client x520wan del 2>/dev/null || true

echo 'VPP_PPPOE_MODE=linux' > /etc/default/vpp-pppoe-mode
rm -f /etc/default/vpp-pppoe-native

# Softpath: BD20 bridges x520wan <-> tap20 (vpp-pppoe) for Linux pppd
if [ -x /usr/local/sbin/vpp-bootstrap.sh ]; then
  /usr/local/sbin/vpp-bootstrap.sh
else
  $VPP set interface state x520wan up 2>/dev/null || true
  if ! $VPP show interface 2>/dev/null | grep -q '^tap20'; then
    $VPP create tap id 20 host-if-name vpp-pppoe host-mtu-size 1500 \
      num-rx-queues 4 num-tx-queues 4 rx-ring-size 4096 tx-ring-size 4096
  fi
  $VPP set interface state tap20 up 2>/dev/null || true
  $VPP create bridge-domain 20 2>/dev/null || true
  $VPP set interface l2 bridge x520wan 20 2>/dev/null || true
  $VPP set interface l2 bridge tap20 20 2>/dev/null || true
  ip link set vpp-pppoe up 2>/dev/null || true
fi

systemctl unmask pppoe-vpp.service 2>/dev/null || true
systemctl enable pppoe-vpp.service
systemctl reset-failed pppoe-vpp.service 2>/dev/null || true
systemctl restart pppoe-vpp.service

# Wait for ppp0
i=0
while [ "$i" -lt 60 ]; do
  if ip link show ppp0 >/dev/null 2>&1 && ip -4 addr show ppp0 2>/dev/null | grep -q 'inet '; then
    break
  fi
  i=$((i + 1))
  sleep 1
done

ip -br addr show ppp0 2>/dev/null || true
ip -6 addr show ppp0 2>/dev/null | head -8 || true
echo "pd-digi-linux: Digi PPPoE is Linux pppd (pppoe-vpp) — VPP native client off"
