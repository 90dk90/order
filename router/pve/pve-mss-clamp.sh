#!/bin/bash
iptables -t mangle -C OUTPUT -p tcp --tcp-flags SYN,RST SYN -o vmbr0 -j TCPMSS --set-mss 1408 2>/dev/null || \
  iptables -t mangle -A OUTPUT -p tcp --tcp-flags SYN,RST SYN -o vmbr0 -j TCPMSS --set-mss 1408
iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -o vmbr0 -j TCPMSS --set-mss 1408 2>/dev/null || \
  iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -o vmbr0 -j TCPMSS --set-mss 1408
