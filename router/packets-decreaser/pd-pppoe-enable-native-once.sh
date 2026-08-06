#!/bin/bash
# One-shot: kernel Digi WAN/PPPoE → VPP native pppoeclient + VPP VXLAN.
#
# Cost: exactly ONE Digi PPPoE flap + ONE `systemctl restart vpp`
#       (dpdk-bind runs via Requires=; not a full OS reboot).
#
# Prerequisites:
#   - Backup at /root/pd-backup-kernel-mode-*.tgz (create first)
#   - soft-handoff plugin already installed (show pppoeclient soft-handoff)
#   - PD_ALLOW_PPPOE_RESTART=1 PD_ALLOW_VPP_RESTART=1
#
# Safety:
#   - NEVER af_packet / host-interface on enp36s0
#   - Does NOT bind unused 0000:01:00.x into DPDK
#   - Keeps kernel.sched_rt_runtime_us=-1
set -euo pipefail

if [ "${PD_ALLOW_PPPOE_RESTART:-0}" != "1" ] || [ "${PD_ALLOW_VPP_RESTART:-0}" != "1" ]; then
  echo "usage: PD_ALLOW_PPPOE_RESTART=1 PD_ALLOW_VPP_RESTART=1 $0" >&2
  exit 1
fi

VPP="${VPP:-/usr/bin/vppctl}"
STARTUP="${VPP_STARTUP:-/etc/vpp/startup.conf}"
BIND_SH="${DPDK_BIND_SH:-/usr/local/sbin/dpdk-bind-x520.sh}"
WAN_PCI="${DIGI_WAN_PCI:-0000:2b:00.0}"
LAN_PCI="${DIGI_LAN_PCI:-0000:2b:00.1}"
TS=$(date -u +%Y%m%d%H%M%S)
BACKUP_GLOB=/root/pd-backup-kernel-mode-*.tgz

echo "pd-pppoe-enable-native-once: kernel → VPP native (ONE vpp restart)"

# --- require backup ---
if ! ls $BACKUP_GLOB >/dev/null 2>&1; then
  echo "pd-pppoe-enable-native-once: missing $BACKUP_GLOB — refuse without backup" >&2
  exit 1
fi
ls -lh $BACKUP_GLOB | tail -3

# --- persist mode before restart ---
mkdir -p /etc/default
echo 'VPP_PPPOE_MODE=native' >/etc/default/vpp-pppoe-mode

# --- backup live files again (thin) ---
cp -a "$STARTUP" "${STARTUP}.bak-before-native-${TS}"
cp -a "$BIND_SH" "${BIND_SH}.bak-before-native-${TS}"

# --- restore DPDK WAN+LAN in startup (no unused fibre extras; txq 8) ---
python3 - "$STARTUP" "$WAN_PCI" "$LAN_PCI" <<'PY'
import re, sys
path, wan, lan = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path).read()
block = f"""
dpdk {{
  uio-driver uio_pci_generic
  socket-mem 2048
  # Intel X520/82599 hard-caps RX/TX descriptors at 4096 (8192 will not probe).
  # Native PPPoE: WAN+LAN in DPDK. Do NOT bind unused 0000:01:00.x.
  # num-tx-queues >= workers+main so TX queues are not shared with vpp_main.
  dev {wan} {{
    name x520wan
    num-rx-queues 4
    num-tx-queues 8
    num-rx-desc 4096
    num-tx-desc 4096
  }}
  dev {lan} {{
    name x520lan
    num-rx-queues 4
    num-tx-queues 8
    num-rx-desc 4096
    num-tx-desc 4096
  }}
}}
"""
new, n = re.subn(r"\ndpdk\s*\{.*?\n\}", "\n" + block.strip() + "\n", text, count=1, flags=re.S)
if n != 1:
    sys.exit("failed to rewrite dpdk {} block in startup.conf")
if "name x520wan" not in new or "name x520lan" not in new:
    sys.exit("startup.conf rewrite missing x520wan/x520lan")
open(path, "w").write(new)
print("startup.conf: DPDK WAN+LAN restored (no extras)")
PY

# --- bind script: MODE!=kernel → WAN+LAN uio (extras stay unbound) ---
cat >"$BIND_SH" <<'EOF'
#!/bin/sh
set -eu
# Digi X520 bind — WAN+LAN on uio when MODE=native/linux; WAN on ixgbe when MODE=kernel.
# Do NOT bind unused 0000:01:00.x (down fibre) into DPDK.
/sbin/modprobe uio_pci_generic
/sbin/modprobe ixgbe

MODE=linux
if [ -r /etc/default/vpp-pppoe-mode ]; then
  # shellcheck disable=SC1091
  . /etc/default/vpp-pppoe-mode
  MODE="${VPP_PPPOE_MODE:-linux}"
fi

LAN="0000:2b:00.1"
WAN="0000:2b:00.0"
EXTRAS="0000:01:00.0 0000:01:00.1"

/usr/bin/dpdk-devbind.py -u $EXTRAS >/dev/null 2>&1 || true

if [ "$MODE" = "kernel" ]; then
  /usr/bin/dpdk-devbind.py -u $LAN >/dev/null 2>&1 || true
  /usr/bin/dpdk-devbind.py -b uio_pci_generic $LAN
  /usr/bin/dpdk-devbind.py -u $WAN >/dev/null 2>&1 || true
  /usr/bin/dpdk-devbind.py -b ixgbe $WAN
else
  /usr/bin/dpdk-devbind.py -u $WAN $LAN >/dev/null 2>&1 || true
  /usr/bin/dpdk-devbind.py -b uio_pci_generic $WAN $LAN
fi
EOF
chmod 0755 "$BIND_SH"

# --- stop kernel PPPoE / Linux VXLAN underlay (before NIC leaves ixgbe) ---
systemctl stop pppoe-vpp.service 2>/dev/null || true
systemctl disable pppoe-vpp.service 2>/dev/null || true
systemctl mask pppoe-vpp.service 2>/dev/null || true
ip link del vxlan-digi 2>/dev/null || true
ip link set digi-wan down 2>/dev/null || true
# keep RT fix
sysctl -w kernel.sched_rt_runtime_us=-1 >/dev/null 2>&1 || true

# --- ONE VPP restart (dpdk-bind via Requires=) ---
echo "pd-pppoe-enable-native-once: restarting VPP once…"
systemctl restart dpdk-bind-x520.service
systemctl restart vpp.service
for i in $(seq 1 60); do
  if $VPP show version >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
$VPP show version >/dev/null

systemctl start vpp-bootstrap.service
systemctl reset-failed vpp-pppoe-native.service 2>/dev/null || true
systemctl unmask vpp-pppoe-native.service 2>/dev/null || true
systemctl enable vpp-pppoe-native.service
systemctl restart vpp-pppoe-native.service

# --- wait Digi IPv4 + GUA ---
SRC=""
for i in $(seq 1 120); do
  if $VPP show pppoe client 2>/dev/null | grep -q PPPOE_CLIENT_SESSION; then
    SRC=$($VPP show pppoe client detail 2>/dev/null | sed -n 's/.*wan-ipv6 observed \([^ /]*\).*/\1/p' | tr -d '\r' | head -1)
    SRC=${SRC%%/*}
    if [ -n "$SRC" ] && [ "$SRC" != "<none>" ]; then
      break
    fi
    SRC=$($VPP show interface addr digi 2>/dev/null | awk '/L3 2a/{gsub(/\/.*/,"",$2); print $2; exit}')
    if [ -n "$SRC" ]; then
      break
    fi
  fi
  sleep 1
done
if [ -z "${SRC:-}" ]; then
  echo "pd-pppoe-enable-native-once: no Digi GUA yet — check: vppctl show pppoe client detail" >&2
  $VPP show pppoe client detail 2>/dev/null | head -40 || true
  exit 1
fi
echo "pd-pppoe-enable-native-once: Digi GUA $SRC"

# soft-handoff should already be on in plugin
$VPP set pppoeclient soft-handoff on 2>/dev/null || true
$VPP show pppoeclient soft-handoff 2>/dev/null | tr -d '\r' | head -8 || true

# --- VPP VXLAN cutover + VPS sync ---
printf '%s\n' "$SRC" >/run/pd-vxlan-digi-vtep.txt
printf '%s\n' "$SRC" >/run/pd-digi-vtep.txt
/usr/local/sbin/pd-vpp-digi-vxlan-cutover.sh
# Best-effort VPS peer refresh (script runs on VPS, not Digi)
if [ -r /root/.ssh/id_ed25519_pd_vps ]; then
  ssh -i /root/.ssh/id_ed25519_pd_vps -o BatchMode=yes -o ConnectTimeout=8 \
    root@77.90.4.48 "DIGI_VTEP=$SRC /usr/local/sbin/pd-vpp-digi-vxlan-vps.sh" \
    >/tmp/pd-native-vxlan-vps.out 2>&1 || \
    echo "pd-pppoe-enable-native-once: VPS sync failed — see /tmp/pd-native-vxlan-vps.out (retry with DIGI_VTEP=$SRC)"
fi
/usr/local/sbin/pd-rss-tune.sh 2>/dev/null || true
/usr/local/sbin/vpp-performance-tuning.sh 2>/dev/null || true

cat >/etc/default/pd-underlay <<EOF
# Digi native VPP PPPoE + VPP VXLAN (post pd-pppoe-enable-native-once)
PD_UNDERLAY=digi-vxlan
PD_TRANSPORT=vxlan
PD_GRE=0
PD_PPPOE=1
VPP_PPPOE_MODE=native
DIGI_VTEP=$SRC
DIGI_VXLAN_INSTANCE=209
PD_ALLOW_VPP_RESTART=0
PD_ALLOW_PPPOE_RESTART=0
EOF

echo "pd-pppoe-enable-native-once: DONE gua=$SRC"
echo "Rollback kernel: PD_ALLOW_PPPOE_RESTART=1 PD_ALLOW_VPP_RESTART=1 /usr/local/sbin/pd-pppoe-enable-kernel-once.sh"
echo "Backup: $(ls -1 $BACKUP_GLOB | tail -1)"
$VPP show int addr digi 2>/dev/null | head -10 || true
$VPP show vxlan tunnel 2>/dev/null | head -20 || true
