#!/bin/bash
# Disable Digi PPPoE + GRE path completely (Proximus VPP VXLAN mode).
# Does not restart VPP by itself — pair with pd-vpp-prox-vxlan-activate.sh.
set -euo pipefail

systemctl stop pd-gre-watchdog.timer pd-gre-watchdog.service 2>/dev/null || true
systemctl disable pd-gre-watchdog.timer 2>/dev/null || true
systemctl stop pd-vxlan-lab-arm.timer pd-vxlan-lab-arm.service 2>/dev/null || true
systemctl disable pd-vxlan-lab-arm.timer 2>/dev/null || true

# PPPoE stacks (native + linux softpath + old vxlan-ipv6 underlay)
for u in vpp-pppoe-native.service pppoe-vpp.service vpp-vxlan.service wide-dhcpv6-client.service; do
  systemctl stop "$u" 2>/dev/null || true
  systemctl disable "$u" 2>/dev/null || true
  systemctl mask "$u" 2>/dev/null || true
done

# Tear down Linux Proximus VXLAN hairpin (replaced by VPP VXLAN)
ip link del vxlan-prox 2>/dev/null || true
ip rule del from 79.172.242.0/24 table 208 2>/dev/null || true
ip rule del iif vpp-vxlan-lab table 208 2>/dev/null || true
ip route flush table 208 2>/dev/null || true
ip route del 79.172.242.0/24 via 10.255.208.1 2>/dev/null || true

# Mode flag for bootstrap
mkdir -p /etc/default
cat >/etc/default/pd-underlay <<'EOF'
# proximus-vpp: VXLAN in VPP over Proximus (enp36s0). Digi PPPoE disabled.
PD_UNDERLAY=proximus-vpp
PD_PPPOE=0
EOF

# Force bootstrap out of native PPPoE bridge mode
echo 'VPP_PPPOE_MODE=disabled' >/etc/default/vpp-pppoe-mode

echo "pd-pppoe-disable: PPPoE/GRE timers masked; Linux vxlan-prox removed; PD_UNDERLAY=proximus-vpp"
