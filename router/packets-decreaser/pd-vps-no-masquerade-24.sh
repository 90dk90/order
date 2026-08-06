#!/bin/bash
# PD VPS: egress with real 79.172.242.0/24 (BGP) — remove eth0 MASQUERADE.
# Replaces the old pd-egress-nat.sh behaviour (which SNATed to 77.90.4.48).
# Opt back into NAT only with: PD_MASQUERADE_24=1 (not recommended when /24 is announced).
set -euo pipefail

IF="${PD_VPS_IF:-eth0}"

if [ "${PD_MASQUERADE_24:-0}" = "1" ]; then
  iptables -t nat -C POSTROUTING -s 79.172.242.0/24 -o "$IF" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -I POSTROUTING 1 -s 79.172.242.0/24 -o "$IF" -j MASQUERADE
  echo "pd-vps-no-masquerade-24: MASQUERADE enabled (PD_MASQUERADE_24=1)"
else
  while iptables -t nat -C POSTROUTING -s 79.172.242.0/24 -o "$IF" -j MASQUERADE 2>/dev/null; do
    iptables -t nat -D POSTROUTING -s 79.172.242.0/24 -o "$IF" -j MASQUERADE || break
  done
  echo "pd-vps-no-masquerade-24: MASQUERADE removed — /24 real egress"
fi

iptables -C FORWARD -s 79.172.242.0/24 -j ACCEPT 2>/dev/null || \
  iptables -I FORWARD 1 -s 79.172.242.0/24 -j ACCEPT
iptables -C FORWARD -d 79.172.242.0/24 -j ACCEPT 2>/dev/null || \
  iptables -I FORWARD 1 -d 79.172.242.0/24 -j ACCEPT

if command -v netfilter-persistent >/dev/null 2>&1; then
  netfilter-persistent save 2>/dev/null || true
elif [ -d /etc/iptables ]; then
  iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
fi

iptables -t nat -S POSTROUTING | cat
