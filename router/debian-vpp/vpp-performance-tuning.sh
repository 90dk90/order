#!/bin/sh
set -eu

# VPP workers = cores 2-5 (startup.conf + isolcpus).
# Linux softpath (PPPoE + IPv6 underlay + Digi SNAT) = CPU0+CPU1 only.
LINUX_CPUS_HEX="03"
LINUX_CPUS_LIST="0-1"

if [ -w /sys/devices/system/cpu/cpufreq/boost ]; then
  echo 1 > /sys/devices/system/cpu/cpufreq/boost || true
fi
for governor in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
  [ -e "$governor" ] || continue
  echo performance > "$governor" 2>/dev/null || true
done

/sbin/sysctl -w net.core.netdev_max_backlog=2000000 >/dev/null 2>&1 || true
/sbin/sysctl -w net.core.netdev_budget=2000 >/dev/null 2>&1 || true
/sbin/sysctl -w net.core.netdev_budget_usecs=25000 >/dev/null 2>&1 || true
/sbin/sysctl -w net.core.dev_weight=600 >/dev/null 2>&1 || true
/sbin/sysctl -w net.core.busy_poll=50 >/dev/null 2>&1 || true
/sbin/sysctl -w net.core.busy_read=50 >/dev/null 2>&1 || true
/sbin/sysctl -w net.core.rps_sock_flow_entries=1048576 >/dev/null 2>&1 || true
/sbin/sysctl -w net.core.somaxconn=16384 >/dev/null 2>&1 || true
/sbin/sysctl -w net.core.rmem_max=268435456 >/dev/null 2>&1 || true
/sbin/sysctl -w net.core.wmem_max=268435456 >/dev/null 2>&1 || true
/sbin/sysctl -w net.core.optmem_max=262144 >/dev/null 2>&1 || true
/sbin/sysctl -w net.ipv4.tcp_rmem="4096 262144 268435456" >/dev/null 2>&1 || true
/sbin/sysctl -w net.ipv4.tcp_wmem="4096 262144 268435456" >/dev/null 2>&1 || true
/sbin/sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
/sbin/sysctl -w net.ipv4.tcp_slow_start_after_idle=0 >/dev/null 2>&1 || true
/sbin/sysctl -w net.ipv4.tcp_mtu_probing=1 >/dev/null 2>&1 || true
/sbin/sysctl -w net.ipv4.tcp_fastopen=3 >/dev/null 2>&1 || true
/sbin/sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
/sbin/sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
/sbin/sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true
/sbin/sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1 || true
/sbin/sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1 || true
/sbin/sysctl -w vm.swappiness=1 >/dev/null 2>&1 || true
/sbin/sysctl -w vm.dirty_ratio=10 >/dev/null 2>&1 || true
/sbin/sysctl -w vm.dirty_background_ratio=3 >/dev/null 2>&1 || true

for iface in ppp0 digi-wan vpp-pppoe vpp6-host vpp-gre-fw vpp-mgmt; do
  [ -d "/sys/class/net/$iface" ] || continue
  for rps in /sys/class/net/"$iface"/queues/rx-*/rps_cpus; do
    [ -e "$rps" ] || continue
    echo "$LINUX_CPUS_HEX" > "$rps" 2>/dev/null || true
  done
  for flow_cnt in /sys/class/net/"$iface"/queues/rx-*/rps_flow_cnt; do
    [ -e "$flow_cnt" ] || continue
    echo 65535 > "$flow_cnt" 2>/dev/null || true
  done
  for xps in /sys/class/net/"$iface"/queues/tx-*/xps_cpus; do
    [ -e "$xps" ] || continue
    echo "$LINUX_CPUS_HEX" > "$xps" 2>/dev/null || true
  done
  /sbin/ip link set "$iface" txqueuelen 20000 2>/dev/null || true
  /sbin/tc qdisc replace dev "$iface" root fq 2>/dev/null || true
  /sbin/sysctl -w "net.ipv4.conf.$iface.rp_filter=0" >/dev/null 2>&1 || true
done

# Keep virtio/tap IRQs on Linux CPUs only
for irq in $(awk -F: '/virtio/ {gsub(/ /,"",$1); print $1}' /proc/interrupts 2>/dev/null); do
  [ -w "/proc/irq/$irq/smp_affinity" ] || continue
  echo "$LINUX_CPUS_HEX" > "/proc/irq/$irq/smp_affinity" 2>/dev/null || true
done

if command -v taskset >/dev/null 2>&1; then
  for pid in $(pidof pppd 2>/dev/null || true); do
    taskset -pc "$LINUX_CPUS_LIST" "$pid" >/dev/null 2>&1 || true
    if command -v chrt >/dev/null 2>&1; then
      chrt -f -p 10 "$pid" >/dev/null 2>&1 || true
    fi
    renice -n -10 -p "$pid" >/dev/null 2>&1 || true
  done
  for pid in $(pidof bird 2>/dev/null || true); do
    taskset -pc "$LINUX_CPUS_LIST" "$pid" >/dev/null 2>&1 || true
  done
fi

# Host tap offloads (best-effort; many are fixed on virtio)
for iface in digi-wan vpp-pppoe vpp6-host; do
  [ -d "/sys/class/net/$iface" ] || continue
  ethtool -K "$iface" gro on gso on sg on 2>/dev/null || true
done

exit 0
