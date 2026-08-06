#!/bin/sh
# pppd ip-up.d — assign Digi GUA after IPv4 is up
sleep 2
/usr/local/sbin/pd-digi-linux-wan6.sh || true
