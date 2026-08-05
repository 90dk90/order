#!/bin/sh
# Restore Infrawire-style PD path:
#   Digi PPPoE native in VPP + GRE gre0 in VPP (PD primary)
#   Proximus enp36s0 = host admin / Tailscale ONLY (no PD GRE underlay)
#
# Safe principles (avoid SIGSEGV churn):
#   - Do not run pd-linux-gre-activate / FOU Proximus path
#   - LAN FIB only if missing (pd-lan-prepare soft)
#   - GRE activate when Digi has observed wan-ipv6 (807f/817f/80ff/…)
#   - Disable linux GRE watchdog timer
set -eu

VPP="/usr/bin/vppctl -s /run/vpp/cli.sock"

echo "pd-restore-infrawire: stopping Linux GRE / FOU primary path"
systemctl disable --now pd-gre-watchdog-linux.timer 2>/dev/null || true
systemctl disable --now pd-linux-gre.service 2>/dev/null || true
ip link del gre-pd 2>/dev/null || true
ip fou del port 4754 2>/dev/null || true
# Detach leftover exit PBR toward Linux GRE (keep Tailscale/Proximus host routing)
ip rule del iif vpp6-host lookup 100 2>/dev/null || true
ip rule del iif vpp-pd-exit lookup 100 2>/dev/null || true
ip route flush table 100 2>/dev/null || true

echo "pd-restore-infrawire: Digi PPPoE native in VPP"
echo 'VPP_PPPOE_MODE=native' > /etc/default/vpp-pppoe-mode
systemctl disable --now pppoe-vpp.service 2>/dev/null || true
systemctl enable vpp-pppoe-native.service 2>/dev/null || true
systemctl start vpp-pppoe-native.service || true

# Soft LAN only if GW missing
if [ -x /usr/local/sbin/pd-lan-prepare.sh ]; then
  if ! $VPP show interface address loop10 2>/dev/null | tr -d '\r' | grep -q '79.172.242.1/32'; then
    echo "pd-restore-infrawire: LAN FIB missing — soft prepare once"
    /usr/local/sbin/pd-lan-prepare.sh || true
  else
    echo "pd-restore-infrawire: LAN FIB already present — skip"
  fi
fi

# Point PD conf back to Digi/VPP GRE semantics
if [ -f /etc/pd/pd-gre.conf ]; then
  sed -i 's/^PD_UNDERLAY=.*/PD_UNDERLAY=digi/' /etc/pd/pd-gre.conf || true
  grep -q '^PD_UNDERLAY=' /etc/pd/pd-gre.conf || echo 'PD_UNDERLAY=digi' >> /etc/pd/pd-gre.conf
  # Explicit: Proximus is admin only
  if grep -q '^PD_PROXIMUS_ROLE=' /etc/pd/pd-gre.conf; then
    sed -i 's/^PD_PROXIMUS_ROLE=.*/PD_PROXIMUS_ROLE=admin/' /etc/pd/pd-gre.conf
  else
    echo 'PD_PROXIMUS_ROLE=admin' >> /etc/pd/pd-gre.conf
  fi
  # Do not wire Linux exit tap for PD
  if grep -q '^PD_ENABLE_EXIT_TAP=' /etc/pd/pd-gre.conf; then
    sed -i 's/^PD_ENABLE_EXIT_TAP=.*/PD_ENABLE_EXIT_TAP=0/' /etc/pd/pd-gre.conf
  else
    echo 'PD_ENABLE_EXIT_TAP=0' >> /etc/pd/pd-gre.conf
  fi
fi

echo "pd-restore-infrawire: enable classic VPP GRE watchdog (no linux FOU)"
systemctl disable --now pd-gre-watchdog-linux.timer 2>/dev/null || true
if [ -f /etc/systemd/system/pd-gre-watchdog.timer ] || [ -f /lib/systemd/system/pd-gre-watchdog.timer ]; then
  systemctl enable --now pd-gre-watchdog.timer 2>/dev/null || true
fi

# Attempt GRE only if Digi already has a real VTEP
if [ -x /usr/local/sbin/pd-gre-activate.sh ]; then
  echo "pd-restore-infrawire: trying pd-gre-activate (no-op if Digi IPv6 missing)"
  /usr/local/sbin/pd-gre-activate.sh || true
fi

echo "=== Digi / GRE status ==="
$VPP show pppoe client detail 2>/dev/null | tr -d '\r' | head -40 || true
$VPP show gre tunnel 2>/dev/null | tr -d '\r' || true
$VPP show interface gre0 2>/dev/null | tr -d '\r' | head -8 || true
echo "pd-restore-infrawire: done (Proximus left for Tailscale/admin host path)"
