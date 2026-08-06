#!/bin/bash
# ONE planned Digi cutover: VPP native pppoeclient → Linux kernel pppd/rp-pppoe
# (TAP hairpin: x520wan L2-bridged to host if vpp-pppoe).
#
# Does NOT unbind DPDK. Does NOT touch enp36s0.
# Flaps Digi PPPoE session once (native tear-down → pppd dial).
set -euo pipefail
. /usr/local/sbin/pd-no-flap.sh 2>/dev/null || true

if [ "${PD_ALLOW_PPPOE_RESTART:-0}" != "1" ]; then
  echo "usage: PD_ALLOW_PPPOE_RESTART=1 $0" >&2
  echo "Refusing accidental Digi PPPoE flaps." >&2
  exit 1
fi

if ! command -v vppctl >/dev/null 2>&1; then
  echo "pd-pppoe-enable-linux-once: vppctl missing" >&2
  exit 1
fi

if ! systemctl cat pppoe-vpp.service >/dev/null 2>&1; then
  echo "pd-pppoe-enable-linux-once: pppoe-vpp.service missing on Digi — install debian-vpp/pppoe-vpp.* first" >&2
  exit 1
fi

# Prefer dedicated helper if present (repo copy may be older/newer)
if [ -x /usr/local/sbin/pd-digi-linux-pppoe.sh ]; then
  /usr/local/sbin/pd-digi-linux-pppoe.sh
elif [ -x /usr/local/sbin/vpp-pppoe-rollback-linux.sh ]; then
  /usr/local/sbin/vpp-pppoe-rollback-linux.sh
else
  echo "pd-pppoe-enable-linux-once: no linux cutover script installed" >&2
  exit 1
fi

# RPS / softpath tune (CPU0-1 for Linux; VPP workers stay isolated)
if [ -x /usr/local/sbin/vpp-performance-tuning.sh ]; then
  /usr/local/sbin/vpp-performance-tuning.sh || true
fi

echo "pd-pppoe-enable-linux-once: mode=linux (pppd/rp-pppoe on vpp-pppoe)"
echo "Check:"
echo "  systemctl status pppoe-vpp --no-pager"
echo "  ip -br addr show ppp0"
echo "  journalctl -u pppoe-vpp -n 40 --no-pager"
ip -br addr show ppp0 2>/dev/null || true
systemctl is-active pppoe-vpp.service 2>/dev/null || true
