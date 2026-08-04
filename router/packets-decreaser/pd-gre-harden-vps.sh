#!/bin/bash
# PD BGP VPS: reduce Digi VTEP / GRE inner leakage via ICMP errors & forward probes.
# Idempotent on VTEP renumber: clears previous Digi-destination jumps before re-adding.
set -euo pipefail
ENV_FILE=/etc/pd-gre.env
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
DIGI_VTEP="${DIGI_VTEP:?DIGI_VTEP required}"
INNER_IP=$(printf '%s\n' "${INNER_LOCAL:-172.16.207.1/30}" | cut -d/ -f1)
STATE=/var/lib/pd-gre-harden-vps.state

sysctl -q -w net.ipv4.ip_forward=1
sysctl -q -w net.ipv4.conf.all.accept_redirects=0
sysctl -q -w net.ipv4.conf.default.accept_redirects=0
sysctl -q -w net.ipv6.conf.all.accept_redirects=0
sysctl -q -w net.ipv6.conf.default.accept_redirects=0
sysctl -q -w net.ipv4.conf.all.send_redirects=0
sysctl -q -w net.ipv4.conf.default.send_redirects=0
if ip link show gre-pd >/dev/null 2>&1; then
  sysctl -q -w net.ipv4.conf.gre-pd.accept_redirects=0 2>/dev/null || true
  sysctl -q -w net.ipv4.conf.gre-pd.send_redirects=0 2>/dev/null || true
  sysctl -q -w net.ipv4.conf.gre-pd.rp_filter=0 2>/dev/null || true
fi

for src in "$INNER_IP" 77.90.4.48; do
  iptables -C OUTPUT -p icmp --icmp-type time-exceeded -s "$src" -j DROP 2>/dev/null || \
    iptables -I OUTPUT -p icmp --icmp-type time-exceeded -s "$src" -j DROP
done
iptables -C OUTPUT -o gre-pd -p icmp --icmp-type time-exceeded -j DROP 2>/dev/null || \
  iptables -I OUTPUT -o gre-pd -p icmp --icmp-type time-exceeded -j DROP 2>/dev/null || true
iptables -C OUTPUT -o gre-pd -p icmp --icmp-type destination-unreachable -j DROP 2>/dev/null || \
  iptables -I OUTPUT -o gre-pd -p icmp --icmp-type destination-unreachable -j DROP 2>/dev/null || true

if command -v ip6tables >/dev/null 2>&1; then
  # Drop jumps aimed at any previous Digi VTEP we tracked
  if [ -r "$STATE" ]; then
    # shellcheck disable=SC1090
    . "$STATE"
    if [ -n "${LAST_DIGI_VTEP:-}" ] && [ "$LAST_DIGI_VTEP" != "$DIGI_VTEP" ]; then
      ip6tables -D OUTPUT -d "$LAST_DIGI_VTEP/128" -j PD_HIDE_DIGI 2>/dev/null || true
      ip6tables -D FORWARD -d "$LAST_DIGI_VTEP/128" -j DROP 2>/dev/null || true
    fi
  fi
  # Also sweep any OUTPUT/FORWARD lines that still point at other Digi 807f hosts
  ip6tables -S OUTPUT 2>/dev/null | awk '/2a01:4700:807f:ffff::/ && /PD_HIDE_DIGI/ {
    s=$0; sub(/^-A /,"-D ",s); print s
  }' | while read -r cmd; do
    # shellcheck disable=SC2086
    ip6tables $cmd 2>/dev/null || true
  done
  ip6tables -S FORWARD 2>/dev/null | awk '/2a01:4700:807f:ffff::/ && /-j DROP/ {
    s=$0; sub(/^-A /,"-D ",s); print s
  }' | while read -r cmd; do
    # shellcheck disable=SC2086
    ip6tables $cmd 2>/dev/null || true
  done

  ip6tables -N PD_HIDE_DIGI 2>/dev/null || ip6tables -F PD_HIDE_DIGI
  ip6tables -F PD_HIDE_DIGI
  ip6tables -A PD_HIDE_DIGI -p 47 -d "$DIGI_VTEP/128" -j ACCEPT
  ip6tables -A PD_HIDE_DIGI -p ipv6-icmp --icmpv6-type echo-request -d "$DIGI_VTEP/128" -j ACCEPT
  ip6tables -A PD_HIDE_DIGI -p ipv6-icmp --icmpv6-type echo-reply -d "$DIGI_VTEP/128" -j ACCEPT
  ip6tables -A PD_HIDE_DIGI -d "$DIGI_VTEP/128" -j DROP

  ip6tables -C OUTPUT -d "$DIGI_VTEP/128" -j PD_HIDE_DIGI 2>/dev/null || \
    ip6tables -I OUTPUT -d "$DIGI_VTEP/128" -j PD_HIDE_DIGI
  ip6tables -C FORWARD -d "$DIGI_VTEP/128" -j DROP 2>/dev/null || \
    ip6tables -I FORWARD -d "$DIGI_VTEP/128" -j DROP
  ip6tables -C OUTPUT -p ipv6-icmp --icmpv6-type time-exceeded -j DROP 2>/dev/null || \
    ip6tables -I OUTPUT -p ipv6-icmp --icmpv6-type time-exceeded -j DROP
fi

mkdir -p "$(dirname "$STATE")"
printf 'LAST_DIGI_VTEP=%s\n' "$DIGI_VTEP" > "$STATE"

if command -v netfilter-persistent >/dev/null 2>&1; then
  netfilter-persistent save >/dev/null 2>&1 || true
fi

echo "pd-gre-harden-vps ok digi=$DIGI_VTEP inner=$INNER_IP"
