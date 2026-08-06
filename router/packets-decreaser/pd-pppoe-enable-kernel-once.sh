#!/bin/bash
# One-shot: move Digi WAN NIC (0000:2b:00.0) from VPP/DPDK to kernel ixgbe
# and run pppd/rp-pppoe directly on it (no BD20/tap20 hairpin).
#
# Why: removes VPP softpath drops (vpp-pppoe TX drop / x520wan rx-miss under load).
# Cost: ONE Digi PPPoE flap + ONE VPP restart (DPDK unbind requires it).
#
# Safety:
#   - NEVER touches enp36s0 / af_packet
#   - Keeps x520lan + x520extra* in DPDK for LAN
#   - Requires PD_ALLOW_PPPOE_RESTART=1 PD_ALLOW_VPP_RESTART=1
set -eu

if [ "${PD_ALLOW_PPPOE_RESTART:-0}" != "1" ] || [ "${PD_ALLOW_VPP_RESTART:-0}" != "1" ]; then
  echo "usage: PD_ALLOW_PPPOE_RESTART=1 PD_ALLOW_VPP_RESTART=1 $0" >&2
  exit 1
fi

WAN_PCI="${DIGI_WAN_PCI:-0000:2b:00.0}"
WAN_IF_NAME="${DIGI_WAN_IFACE:-digi-wan}"
VPP="${VPP:-/usr/bin/vppctl}"
STARTUP="${VPP_STARTUP:-/etc/vpp/startup.conf}"
BIND_SH="${DPDK_BIND_SH:-/usr/local/sbin/dpdk-bind-x520.sh}"
PEER="${PPP_PEER:-vpp-pppoe}"
TS=$(date +%Y%m%d%H%M%S)

echo "pd-pppoe-enable-kernel-once: Digi WAN $WAN_PCI → kernel ($WAN_IF_NAME), one VPP+PPPoE flap"

# Persist mode before restart so bootstrap skips BD20
mkdir -p /etc/default
echo 'VPP_PPPOE_MODE=kernel' >/etc/default/vpp-pppoe-mode
# Stable netdev name across reboots
cat >/etc/systemd/network/10-digi-wan.link <<EOF
[Match]
Path=pci-${WAN_PCI}

[Link]
Name=${WAN_IF_NAME}
EOF

# Backup + strip x520wan from VPP DPDK stanza
cp -a "$STARTUP" "${STARTUP}.bak-before-kernel-wan-${TS}"
python3 - "$STARTUP" "$WAN_PCI" <<'PY'
import re, sys
path, pci = sys.argv[1], sys.argv[2]
text = open(path).read()
# Remove the whole "dev <pci> { ... }" block for WAN
pat = re.compile(
    r"\n[ \t]*dev[ \t]+" + re.escape(pci) + r"[ \t]*\{.*?\n[ \t]*\}",
    re.S,
)
new, n = pat.subn("\n  # Digi WAN " + pci + " moved to kernel ixgbe (VPP_PPPOE_MODE=kernel)\n", text, count=1)
if n != 1:
    # already removed?
    if "name x520wan" in new:
        sys.exit("failed to remove x520wan/dev %s from startup.conf" % pci)
open(path, "w").write(new)
print("startup.conf: removed DPDK dev", pci)
PY

# Rewrite DPDK bind: keep LAN+extras on uio; WAN on ixgbe
cp -a "$BIND_SH" "${BIND_SH}.bak-before-kernel-wan-${TS}"
cat >"$BIND_SH" <<'EOF'
#!/bin/sh
set -eu
# Digi X520 bind — WAN (2b:00.0) stays on kernel ixgbe when MODE=kernel.
/sbin/modprobe uio_pci_generic
/sbin/modprobe ixgbe

MODE=linux
if [ -r /etc/default/vpp-pppoe-mode ]; then
  # shellcheck disable=SC1091
  . /etc/default/vpp-pppoe-mode
  MODE="${VPP_PPPOE_MODE:-linux}"
fi

LAN_EXTRAS="0000:2b:00.1 0000:01:00.0 0000:01:00.1"
WAN="0000:2b:00.0"

if [ "$MODE" = "kernel" ]; then
  /usr/bin/dpdk-devbind.py -u $LAN_EXTRAS >/dev/null 2>&1 || true
  /usr/bin/dpdk-devbind.py -b uio_pci_generic $LAN_EXTRAS
  /usr/bin/dpdk-devbind.py -u $WAN >/dev/null 2>&1 || true
  /usr/bin/dpdk-devbind.py -b ixgbe $WAN
else
  /usr/bin/dpdk-devbind.py -u $WAN $LAN_EXTRAS >/dev/null 2>&1 || true
  /usr/bin/dpdk-devbind.py -b uio_pci_generic $WAN $LAN_EXTRAS
fi
EOF
chmod 0755 "$BIND_SH"

# PPPoE unit: no longer BindsTo VPP (kernel NIC survives VPP restarts)
cp -a /etc/systemd/system/pppoe-vpp.service \
  "/etc/systemd/system/pppoe-vpp.service.bak-before-kernel-wan-${TS}"
cat >/etc/systemd/system/pppoe-vpp.service <<EOF
[Unit]
Description=Digi PPPoE client on kernel WAN (${WAN_IF_NAME})
After=network-pre.target systemd-udev-settle.service
Wants=network-pre.target
# Intentionally NOT BindsTo=vpp — Digi session must survive VPP restarts
StartLimitIntervalSec=10min
StartLimitBurst=20

[Service]
Type=simple
ExecStartPre=/sbin/modprobe ixgbe
ExecStartPre=/bin/sh -c 'ip link set ${WAN_IF_NAME} up || true'
ExecStart=/usr/sbin/pppd call ${PEER}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Stop PPPoE before VPP restart (single intentional Digi flap window)
systemctl stop pppoe-vpp.service 2>/dev/null || true
systemctl mask vpp-pppoe-native.service 2>/dev/null || true
systemctl disable vpp-pppoe-native.service 2>/dev/null || true

# Apply bind + VPP restart (one shot)
systemctl daemon-reload
"$BIND_SH"
# Rename netdev if udev.link not yet applied this boot
if [ ! -d "/sys/class/net/${WAN_IF_NAME}" ]; then
  raw=$(basename "$(ls -d /sys/bus/pci/devices/${WAN_PCI}/net/* 2>/dev/null | head -1)" || true)
  if [ -n "${raw:-}" ] && [ "$raw" != "$WAN_IF_NAME" ]; then
    ip link set "$raw" down 2>/dev/null || true
    ip link set "$raw" name "$WAN_IF_NAME" 2>/dev/null || true
  fi
fi
[ -d "/sys/class/net/${WAN_IF_NAME}" ] || {
  echo "pd-pppoe-enable-kernel-once: kernel iface for $WAN_PCI missing after ixgbe bind" >&2
  dpdk-devbind.py -s || true
  exit 1
}

echo "pd-pppoe-enable-kernel-once: restarting VPP once (LAN stays DPDK; WAN is kernel)"
systemctl restart vpp.service
for i in $(seq 1 90); do
  $VPP show version >/dev/null 2>&1 && break
  sleep 1
done
$VPP show version >/dev/null

# Bootstrap without x520wan
systemctl start vpp-bootstrap.service || /usr/local/sbin/vpp-bootstrap.sh || true

# Point pppd peer at kernel NIC
if [ -f "/etc/ppp/peers/${PEER}" ]; then
  cp -a "/etc/ppp/peers/${PEER}" "/etc/ppp/peers/${PEER}.bak-before-kernel-wan-${TS}"
  if grep -qE '^nic-' "/etc/ppp/peers/${PEER}"; then
    sed -i "s/^nic-.*/nic-${WAN_IF_NAME}/" "/etc/ppp/peers/${PEER}"
  else
    echo "nic-${WAN_IF_NAME}" >>"/etc/ppp/peers/${PEER}"
  fi
else
  echo "pd-pppoe-enable-kernel-once: missing /etc/ppp/peers/${PEER}" >&2
  exit 1
fi

# RPS on Digi WAN (multi-queue ixgbe + softirq spread)
ip link set "$WAN_IF_NAME" up
for rps in /sys/class/net/"$WAN_IF_NAME"/queues/rx-*/rps_cpus; do
  [ -e "$rps" ] || continue
  echo 3 >"$rps" 2>/dev/null || echo f >"$rps" 2>/dev/null || true
done
# Prefer more RX queues if driver allows
ethtool -L "$WAN_IF_NAME" combined 4 2>/dev/null || true
ethtool -G "$WAN_IF_NAME" rx 4096 tx 4096 2>/dev/null || true
# nmcli unmanaged
nmcli device set "$WAN_IF_NAME" managed no >/dev/null 2>&1 || true

systemctl reset-failed pppoe-vpp.service 2>/dev/null || true
systemctl enable pppoe-vpp.service
systemctl restart pppoe-vpp.service

# Wait ppp0
i=0
while [ "$i" -lt 90 ]; do
  if ip link show ppp0 >/dev/null 2>&1 && ip -4 addr show ppp0 2>/dev/null | grep -q 'inet '; then
    break
  fi
  i=$((i + 1))
  sleep 1
done
ip -br addr show ppp0 || {
  echo "pd-pppoe-enable-kernel-once: ppp0 not up — journalctl -u pppoe-vpp -n 80" >&2
  exit 1
}

# Digi GUA + Linux VXLAN underlay
PD_WAN6_REARM_VXLAN=1 /usr/local/sbin/pd-digi-linux-wan6.sh || true
if [ -x /usr/local/sbin/pd-linux-vxlan-digi-activate.sh ]; then
  /usr/local/sbin/pd-linux-vxlan-digi-activate.sh || true
fi

# Drop unused tap20 hairpin if present (best-effort, no VPP restart)
$VPP set interface state tap20 down 2>/dev/null || true
ip link set vpp-pppoe down 2>/dev/null || true

cat >/etc/default/pd-underlay <<EOF
# Digi WAN on kernel ixgbe; VPP = LAN only; Linux VXLAN underlay
PD_UNDERLAY=digi-linux-vxlan
PD_TRANSPORT=vxlan
PD_GRE=0
PD_PPPOE=1
VPP_PPPOE_MODE=kernel
DIGI_WAN_IFACE=${WAN_IF_NAME}
DIGI_WAN_PCI=${WAN_PCI}
DIGI_VTEP=$(tr -d ' \r\n' </run/pd-digi-vtep.txt 2>/dev/null || true)
DIGI_LINUX_VXLAN_IF=vxlan-digi
PD_ALLOW_VPP_RESTART=0
PD_ALLOW_PPPOE_RESTART=0
EOF

echo "pd-pppoe-enable-kernel-once: DONE"
ip -br link show "$WAN_IF_NAME"
ip -br addr show ppp0
dpdk-devbind.py -s | sed -n '1,20p'
$VPP show interface | head -20 || true
