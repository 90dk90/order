#!/bin/bash
# PD BGP VPS (77.90.4.48): underlay NIC / softpath tune — no Digi PPPoE touch.
#
# Why: eth0 still had mq+fq (same class of under-load RTT/pacing pain as Digi
# ppp0 before pfifo_fast). netdev_max_backlog=1000 is too small for ~5G forward.
# Idempotent; safe to re-run.
set -euo pipefail

IF="${PD_VPS_IF:-eth0}"
VXLAN_IF="${PD_VPS_VXLAN_IF:-vxlan-lab}"
# Prefer all host CPUs for RPS (VPS has no Digi isolcpus split).
RPS_HEX="${PD_VPS_RPS_HEX:-}"
if [ -z "$RPS_HEX" ]; then
  n="$(nproc 2>/dev/null || echo 1)"
  # mask of n low bits
  RPS_HEX="$(printf '%x' "$(( (1 << n) - 1 ))")"
fi

sysctl -q -w net.core.netdev_max_backlog=2000000 || true
sysctl -q -w net.core.netdev_budget=600 || true
sysctl -q -w net.core.netdev_budget_usecs=8000 || true
sysctl -q -w net.core.rps_sock_flow_entries=65536 || true
sysctl -q -w net.core.rmem_max=268435456 || true
sysctl -q -w net.core.wmem_max=268435456 || true
sysctl -q -w net.core.somaxconn=16384 || true
sysctl -q -w net.ipv4.tcp_rmem="4096 262144 268435456" || true
sysctl -q -w net.ipv4.tcp_wmem="4096 262144 268435456" || true
sysctl -q -w net.ipv4.tcp_congestion_control=bbr || true
sysctl -q -w net.ipv4.tcp_slow_start_after_idle=0 || true
sysctl -q -w net.ipv4.ip_forward=1 || true
sysctl -q -w net.ipv6.conf.all.forwarding=1 || true

tune_iface() {
  local iface="$1"
  local qdisc_mode="$2"
  [ -d "/sys/class/net/$iface" ] || return 0

  ip link set "$iface" txqueuelen 20000 2>/dev/null || true

  for rps in /sys/class/net/"$iface"/queues/rx-*/rps_cpus; do
    [ -e "$rps" ] || continue
    echo "$RPS_HEX" > "$rps" 2>/dev/null || true
  done
  for flow_cnt in /sys/class/net/"$iface"/queues/rx-*/rps_flow_cnt; do
    [ -e "$flow_cnt" ] || continue
    echo 4096 > "$flow_cnt" 2>/dev/null || true
  done
  for xps in /sys/class/net/"$iface"/queues/tx-*/xps_cpus; do
    [ -e "$xps" ] || continue
    echo "$RPS_HEX" > "$xps" 2>/dev/null || true
  done

  ethtool -K "$iface" gro on gso on tso on sg on 2>/dev/null || true

  case "$qdisc_mode" in
    mq-pfifo)
      # Debian cloud default is mq+fq; "replace parent" often leaves fq in place.
      # Hard delete root then recreate mq + pfifo_fast per TX queue.
      tc qdisc del dev "$iface" root 2>/dev/null || true
      tc qdisc add dev "$iface" root handle 1: mq
      local n i
      n="$(ls -d /sys/class/net/"$iface"/queues/tx-* 2>/dev/null | wc -l)"
      [ "$n" -ge 1 ] || n=4
      i=1
      while [ "$i" -le "$n" ]; do
        tc qdisc add dev "$iface" parent 1:"$(printf '%x' "$i")" pfifo_fast 2>/dev/null || \
          tc qdisc add dev "$iface" parent 1:"$i" pfifo_fast 2>/dev/null || true
        i=$((i + 1))
      done
      ;;
    pfifo)
      tc qdisc replace dev "$iface" root pfifo_fast 2>/dev/null || true
      ;;
    none)
      ;;
  esac
}

tune_iface "$IF" mq-pfifo
# vxlan is usually noqueue; still set RPS/XPS + txqueuelen
tune_iface "$VXLAN_IF" none
if [ -d "/sys/class/net/$VXLAN_IF" ]; then
  ethtool -K "$VXLAN_IF" gro on gso on sg on rx-udp-gro-forwarding on 2>/dev/null || \
    ethtool -K "$VXLAN_IF" gro on gso on sg on 2>/dev/null || true
fi

# Persist sysctls (qdisc/RPS re-applied by systemd unit or cron if installed)
mkdir -p /etc/sysctl.d
cat >/etc/sysctl.d/99-pd-vps-forward.conf <<'EOF'
net.core.netdev_max_backlog = 2000000
net.core.netdev_budget = 600
net.core.rps_sock_flow_entries = 65536
net.core.rmem_max = 268435456
net.core.wmem_max = 268435456
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_slow_start_after_idle = 0
EOF
sysctl -p /etc/sysctl.d/99-pd-vps-forward.conf >/dev/null 2>&1 || true

echo "pd-vps-nic-tune: ok if=$IF vxlan=$VXLAN_IF rps=$RPS_HEX"
tc qdisc show dev "$IF" | head -8 || true
sysctl net.core.netdev_max_backlog | cat
