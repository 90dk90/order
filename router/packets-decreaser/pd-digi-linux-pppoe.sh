#!/bin/sh
# Move Digi PPPoE off native VPP pppoeclient onto Linux pppd/rp-pppoe
# via TAP hairpin (x520wan <-> BD20 <-> tap20/vpp-pppoe).
#
# Why this path:
#   - Kernel pppd + rp-pppoe is the most battle-tested soft PPPoE client
#   - Keeps x520wan in DPDK (no vfio unbind / no enp36s0 risk)
#   - RPS on vpp-pppoe/ppp0 can spread softirq better than VPP worker-0
#
# Safety: requires PD_ALLOW_PPPOE_RESTART=1 (Digi session flaps once).
set -eu

if [ "${PD_ALLOW_PPPOE_RESTART:-0}" != "1" ]; then
  echo "usage: PD_ALLOW_PPPOE_RESTART=1 $0" >&2
  exit 1
fi

VPP="/usr/bin/vppctl -s /run/vpp/cli.sock"

echo "pd-digi-linux: stopping native Digi PPPoE"
systemctl stop vpp-pppoe-native.service 2>/dev/null || true
systemctl disable vpp-pppoe-native.service 2>/dev/null || true
systemctl mask vpp-pppoe-native.service 2>/dev/null || true

# Drop-in that runs VPP GRE activate — not used in Linux-GRE mode
if [ -f /etc/systemd/system/vpp-pppoe-native.service.d/pd-gre.conf ]; then
  mv /etc/systemd/system/vpp-pppoe-native.service.d/pd-gre.conf \
     /etc/systemd/system/vpp-pppoe-native.service.d/pd-gre.conf.off 2>/dev/null || true
fi

$VPP create pppoe client x520wan host-uniq 1 del 2>/dev/null || true
$VPP create pppoe client x520wan del 2>/dev/null || true
# Leave digi LCP/tun leftovers quiet
ip link set vpp-digi down 2>/dev/null || true

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

# Ensure peer exists (credentials from /etc/default/vpp-pppoe-native or env)
if [ ! -f /etc/ppp/peers/digi ]; then
  echo "pd-digi-linux: missing /etc/ppp/peers/digi — install from debian-vpp/pppoe-peers-digi.example" >&2
  exit 1
fi

systemctl unmask pppoe-vpp.service 2>/dev/null || true
systemctl enable pppoe-vpp.service
systemctl reset-failed pppoe-vpp.service 2>/dev/null || true
systemctl restart pppoe-vpp.service

# Wait for ppp0
i=0
while [ "$i" -lt 90 ]; do
  if ip link show ppp0 >/dev/null 2>&1 && ip -4 addr show ppp0 2>/dev/null | grep -q 'inet '; then
    break
  fi
  i=$((i + 1))
  sleep 1
done

if [ -x /usr/local/sbin/vpp-performance-tuning.sh ]; then
  /usr/local/sbin/vpp-performance-tuning.sh || true
fi

# Extra RPS belt-and-suspenders on the PPPoE softpath (all host CPUs bitmask
# falls back to 0-1 if tuning script already pinned — still better than q0-only).
for iface in vpp-pppoe ppp0; do
  [ -d "/sys/class/net/$iface" ] || continue
  for rps in /sys/class/net/"$iface"/queues/rx-*/rps_cpus; do
    [ -e "$rps" ] || continue
    # Prefer Linux softpath CPUs 0-1 (isolcpus leaves these for host)
    echo 3 > "$rps" 2>/dev/null || echo f > "$rps" 2>/dev/null || true
  done
done

ip -br addr show ppp0 2>/dev/null || {
  echo "pd-digi-linux: ppp0 not up — check: journalctl -u pppoe-vpp -n 80 --no-pager" >&2
  exit 1
}
ip -6 addr show ppp0 2>/dev/null | head -8 || true
echo "pd-digi-linux: Digi PPPoE is Linux pppd/rp-pppoe (pppoe-vpp) — VPP native client off"
echo "Next: re-arm VXLAN VTEP after Digi IPv6 settles:"
echo "  /usr/local/sbin/pd-vpp-digi-vxlan-cutover.sh"
echo "  DIGI_VTEP=<ipv6> /usr/local/sbin/pd-vpp-digi-vxlan-vps.sh"
