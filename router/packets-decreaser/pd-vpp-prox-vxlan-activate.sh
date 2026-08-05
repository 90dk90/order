#!/bin/bash
# One-shot: disable PPPoE, enable VPP plugins, restart VPP, arm Proximus VXLAN + LAN.
# Preserves Linux enp36s0 .7 (Tailscale). Safe cutover for proximus-vpp mode.
set -euo pipefail

/usr/local/sbin/pd-pppoe-disable.sh

# Ensure plugins in live startup.conf
CONF=/etc/vpp/startup.conf
cp -a "$CONF" "/etc/vpp/startup.conf.bak-before-prox-vxlan-$(date +%Y%m%d%H%M%S)"
if ! grep -q 'plugin vxlan_plugin.so { enable }' "$CONF"; then
  sed -i '/plugin gre_plugin.so { enable }/a\  plugin vxlan_plugin.so { enable }\n  plugin af_packet_plugin.so { enable }' "$CONF"
fi
if ! grep -q 'plugin af_packet_plugin.so { enable }' "$CONF"; then
  sed -i '/plugin vxlan_plugin.so { enable }/a\  plugin af_packet_plugin.so { enable }' "$CONF"
fi
# Disable PPPoE plugins (leave files present but unloaded)
sed -i 's/plugin ppp_plugin.so { enable }/plugin ppp_plugin.so { disable }/' "$CONF"
sed -i 's/plugin pppoe_plugin.so { enable }/plugin pppoe_plugin.so { disable }/' "$CONF"
sed -i 's/plugin pppoeclient_plugin.so { enable }/plugin pppoeclient_plugin.so { disable }/' "$CONF"

echo "pd-vpp-prox-vxlan-activate: restarting VPP with vxlan plugin (PPPoE plugins off, no af_packet on enp36s0)..."
# af_packet enabled is OK but we do not bind enp36s0 (SIGSEGV). Keep plugin for later.
systemctl restart vpp
# Wait for CLI
for i in $(seq 1 60); do
  if vppctl show version >/dev/null 2>&1; then break; fi
  sleep 1
done
vppctl show version >/dev/null

# Bootstrap interfaces (x520lan up; x520wan left down in disabled mode)
/usr/local/sbin/vpp-bootstrap.sh || true

# LAN /24 bridge + host /32s
/usr/local/sbin/pd-lan-prepare.sh || true

# Proximus af_packet + VXLAN + table 81
/usr/local/sbin/pd-vpp-prox-vxlan.sh

# Remove leftover tap208 hairpin from VPP if still there
vppctl delete tap id 208 2>/dev/null || true
ip link del vpp-vxlan-lab 2>/dev/null || true

systemctl enable pd-vpp-prox-vxlan.service 2>/dev/null || true

echo "pd-vpp-prox-vxlan-activate: done"
vppctl show vxlan tunnel 2>/dev/null | head -10
vppctl show interface addr proximus 2>/dev/null || vppctl show interface addr host-enp36s0 2>/dev/null || true
