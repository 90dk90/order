#!/bin/sh
# Arm / activate VXLAN lab when Digi IPv6 is back.
# NEVER restarts VPP, NEVER touches PPPoE.
# Requires vxlan_plugin already loaded (one planned VPP restart later if not).
set -eu
VPP="/usr/bin/vppctl -s /run/vpp/cli.sock"
CONF=/etc/pd/pd-vxlan-lab.conf
[ -f "$CONF" ] || CONF=/usr/local/sbin/../packets-decreaser/pd-vxlan-lab.conf
# shellcheck disable=SC1090
. /etc/pd/pd-vxlan-lab.conf 2>/dev/null || . "$CONF"
. /etc/pd/pd-gre.conf 2>/dev/null || true

$VPP show version >/dev/null

# Plugin present?
if ! $VPP show plugins 2>/dev/null | grep -q vxlan_plugin; then
  echo "pd-vxlan-lab-arm: vxlan_plugin NOT loaded yet."
  echo "  When Digi IPv6 is stable, do ONE planned: enable plugin in startup.conf + systemctl restart vpp"
  echo "  (not now). Then re-run this script."
  exit 0
fi

SRC=$($VPP show pppoe client detail 2>/dev/null | sed -n 's/.*wan-ipv6 observed \([^ /]*\).*/\1/p' | tr -d '\r' | head -1)
SRC=${SRC%%/*}
case "$SRC" in
  ""|"<none>"|none)
    SRC=$($VPP show interface addr digi 2>/dev/null | awk '/L3 2a01:4700:/{gsub(/\/.*/,"",$2); print $2; exit}')
    ;;
esac
case "$SRC" in
  ""|"<none>"|none)
    echo "pd-vxlan-lab-arm: Digi global IPv6 not ready — waiting, no changes"
    exit 0
    ;;
esac

echo "pd-vxlan-lab-arm: Digi VTEP=$SRC — activating lab (GRE untouched)"
/usr/local/sbin/pd-vxlan-lab-digi.sh

# Sync VPS lab remote + keep GRE VTEP sync
if [ -x /usr/local/sbin/pd-gre-set-vtep.sh ]; then
  /usr/local/sbin/pd-gre-set-vtep.sh "$SRC" 2>/dev/null || true
fi
# Refresh VPS vxlan-lab remote via SSH if key present
if [ -n "${PD_VPS_SSH:-}" ] && [ -f "${PD_SSH_KEY:-/root/.ssh/id_ed25519_pd_vps}" ]; then
  ssh -i "${PD_SSH_KEY}" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 \
    "$PD_VPS_SSH" "DIGI_VTEP=$SRC /usr/local/sbin/pd-vxlan-lab-vps.sh" 2>/dev/null || true
fi

echo "pd-vxlan-lab-arm: done"
$VPP show vxlan tunnel 2>/dev/null | head -10 || true
$VPP ping "${LAB_VPS:-172.16.208.1}" repeat 3 2>&1 | tail -8 || true
