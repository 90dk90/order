#!/bin/bash
IF=enp16s0
ethtool -G "$IF" rx 8192 tx 8192 2>/dev/null || ethtool -G "$IF" rx 4096 tx 4096 2>/dev/null || true
ethtool -C "$IF" rx-usecs 8 tx-usecs 8 2>/dev/null || true
ethtool -K "$IF" gro on gso on tso on sg on lro off 2>/dev/null || true
ip link set "$IF" txqueuelen 20000 2>/dev/null || true
ip link set vmbr0 txqueuelen 20000 2>/dev/null || true
echo 0 > /sys/class/net/vmbr0/bridge/multicast_snooping 2>/dev/null || true
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > "$g" 2>/dev/null; done

# BBR pacing: fq under mq, not fq_codel
tc qdisc replace dev "$IF" root handle 1: mq 2>/dev/null || true
for i in $(seq 1 16); do
  tc qdisc replace dev "$IF" parent 1:$(printf '%x' $i) handle $((100+i)): fq 2>/dev/null || \
  tc qdisc replace dev "$IF" parent 1:$i handle $((100+i)): fq 2>/dev/null || true
done

sysctl -w net.core.rps_sock_flow_entries=32768 >/dev/null 2>&1 || true
for q in /sys/class/net/$IF/queues/rx-*; do
  echo 4096 > "$q/rps_flow_cnt" 2>/dev/null || true
  echo ff > "$q/rps_cpus" 2>/dev/null || true
done
/usr/local/sbin/pve-mss-clamp.sh
