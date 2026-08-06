#!/bin/bash
# Arm / refresh Proximus VPP VXLAN path.
# By default does NOT restart VPP if vxlan_plugin is already loaded (no-flap).
# PPPoE plugins are re-enabled in startup.conf for a future one-shot bring-up,
# but PPPoE units stay masked until PD_ALLOW_PPPOE_RESTART=1 pd-pppoe-enable-once.sh.
set -euo pipefail
. /usr/local/sbin/pd-no-flap.sh 2>/dev/null || true

/usr/local/sbin/pd-pppoe-disable.sh

CONF=/etc/vpp/startup.conf
cp -a "$CONF" "/etc/vpp/startup.conf.bak-before-prox-vxlan-$(date +%Y%m%d%H%M%S)"

# Ensure VXLAN plugin on
if ! grep -q 'plugin vxlan_plugin.so { enable }' "$CONF"; then
  sed -i '/plugin gre_plugin.so { enable }/a\  plugin vxlan_plugin.so { enable }' "$CONF"
fi
# Keep af_packet plugin available but never bind enp36s0 (SIGSEGV)
if ! grep -q 'plugin af_packet_plugin.so { enable }' "$CONF"; then
  sed -i '/plugin vxlan_plugin.so { enable }/a\  plugin af_packet_plugin.so { enable }' "$CONF"
fi

# Preload PPPoE plugins NOW so later bring-up does not need a VPP restart.
# Session stays down (units masked, PD_PPPOE=0).
sed -i 's/plugin ppp_plugin.so { disable }/plugin ppp_plugin.so { enable }/' "$CONF"
sed -i 's/plugin pppoe_plugin.so { disable }/plugin pppoe_plugin.so { enable }/' "$CONF"
sed -i 's/plugin pppoeclient_plugin.so { disable }/plugin pppoeclient_plugin.so { enable }/' "$CONF"
# If still commented/missing enable lines from older files:
grep -q 'plugin ppp_plugin.so' "$CONF" || sed -i '/plugin tap_plugin.so { enable }/a\  plugin ppp_plugin.so { enable }\n  plugin pppoe_plugin.so { enable }\n  plugin pppoeclient_plugin.so { enable }' "$CONF"

NEED_RESTART=0
vxlan_ok=0
pppoe_ok=0
vppctl show plugins 2>/dev/null | grep -q 'vxlan_plugin' && vxlan_ok=1 || true
vppctl show plugins 2>/dev/null | grep -q 'pppoeclient' && pppoe_ok=1 || true
if [ "$vxlan_ok" != 1 ] || [ "$pppoe_ok" != 1 ]; then
  NEED_RESTART=1
fi

if [ "$NEED_RESTART" = 1 ]; then
  if [ "${PD_ALLOW_VPP_RESTART:-0}" != "1" ]; then
    echo "pd-vpp-prox-vxlan-activate: need one VPP restart to preload plugins." >&2
    echo "  re-run: PD_ALLOW_VPP_RESTART=1 $0" >&2
    exit 2
  fi
  echo "pd-vpp-prox-vxlan-activate: ONE VPP restart (preload vxlan+pppoe plugins; PPPoE session stays masked)..."
  systemctl restart vpp
  for i in $(seq 1 60); do
    vppctl show version >/dev/null 2>&1 && break
    sleep 1
  done
else
  echo "pd-vpp-prox-vxlan-activate: VPP already has vxlan — no restart (no-flap)"
fi

/usr/local/sbin/vpp-bootstrap.sh || true
/usr/local/sbin/pd-lan-prepare.sh || true
/usr/local/sbin/pd-vpp-prox-vxlan.sh
/usr/local/sbin/pd-vpp-vxlan-mss.sh || true

vppctl delete tap id 208 2>/dev/null || true
ip link del vpp-vxlan-lab 2>/dev/null || true

systemctl enable pd-vpp-prox-vxlan.service 2>/dev/null || true
systemctl enable vpp-mss-clamp.service 2>/dev/null || true
systemctl start pd-vpp-prox-vxlan.service 2>/dev/null || true

echo "pd-vpp-prox-vxlan-activate: done (PPPoE still masked; GRE still off)"
vppctl show vxlan tunnel 2>/dev/null | head -5
vppctl show plugins 2>/dev/null | grep -iE "vxlan|pppoeclient|ppp " || true
