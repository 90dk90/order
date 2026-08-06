#!/bin/bash
# Policy guard: refuse actions that flap Digi PPPoE / VPP during PD tests.
# Source from other scripts: . /usr/local/sbin/pd-no-flap.sh
#
# PD_ALLOW_VPP_RESTART=1   — permit systemctl restart vpp (rare: plugin load)
# PD_ALLOW_PPPOE_RESTART=1 — permit stop/start/restart of PPPoE units

pd_refuse_vpp_restart() {
  if [ "${PD_ALLOW_VPP_RESTART:-0}" != "1" ]; then
    if vppctl show vxlan tunnel >/dev/null 2>&1; then
      echo "pd-no-flap: refusing VPP restart (vxlan already loaded). export PD_ALLOW_VPP_RESTART=1 to override." >&2
      return 1
    fi
  fi
  return 0
}

pd_refuse_pppoe_restart() {
  if [ "${PD_ALLOW_PPPOE_RESTART:-0}" != "1" ]; then
    echo "pd-no-flap: refusing PPPoE restart/flap. export PD_ALLOW_PPPOE_RESTART=1 for one planned bring-up." >&2
    return 1
  fi
  return 0
}

pd_pppoe_units() {
  echo vpp-pppoe-native.service pppoe-vpp.service
}
