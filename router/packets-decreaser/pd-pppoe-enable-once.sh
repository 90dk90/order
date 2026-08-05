#!/bin/bash
# ONE planned Digi PPPoE bring-up for VXLAN-only cutover.
# Does NOT restart VPP (vxlan_plugin must already be loaded).
# Does NOT run repeatedly — mask stays until explicit enable.
set -euo pipefail
. /usr/local/sbin/pd-no-flap.sh 2>/dev/null || true

if [ "${PD_ALLOW_PPPOE_RESTART:-0}" != "1" ]; then
  echo "usage: PD_ALLOW_PPPOE_RESTART=1 $0" >&2
  echo "Refusing accidental PPPoE flaps." >&2
  exit 1
fi

# vxlan must already be there — never restart VPP here
if ! vppctl show vxlan tunnel >/dev/null 2>&1; then
  echo "pd-pppoe-enable-once: vxlan_plugin not loaded — load via ONE planned VPP restart first, not this script" >&2
  exit 1
fi

# Update mode before bringing PPPoE
cat >/etc/default/pd-underlay <<'EOF'
# Digi PPPoE bring-up in progress — VXLAN only (GRE stays off).
PD_UNDERLAY=digi-vxlan
PD_TRANSPORT=vxlan
PD_GRE=0
PD_PPPOE=1
PD_ALLOW_VPP_RESTART=0
PD_ALLOW_PPPOE_RESTART=0
EOF
echo 'VPP_PPPOE_MODE=native' >/etc/default/vpp-pppoe-mode

systemctl unmask vpp-pppoe-native.service 2>/dev/null || true
systemctl enable vpp-pppoe-native.service 2>/dev/null || true
# Keep legacy linux softpath masked
systemctl mask pppoe-vpp.service 2>/dev/null || true
# GRE stays dead
systemctl mask pd-gre-watchdog.timer pd-gre-watchdog.service 2>/dev/null || true

systemctl start vpp-pppoe-native.service

echo "pd-pppoe-enable-once: started vpp-pppoe-native (VPP not restarted)."
echo "Wait for global Digi IPv6, then: /usr/local/sbin/pd-vpp-digi-vxlan-cutover.sh"
vppctl show pppoe client detail 2>/dev/null | head -40 || true
