#!/bin/sh
# pppd ipv6-up.d — Digi GUA probe (idempotent with ip-up.d)
/usr/local/sbin/pd-digi-linux-wan6.sh || true
