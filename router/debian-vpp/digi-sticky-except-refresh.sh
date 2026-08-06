#!/usr/bin/env bash
# Periodic refresh of domain→dst exceptions (Cloudflare A records drift).
set -euo pipefail
[ -x /usr/local/sbin/digi-sticky-except-reload.sh ] || exit 0
[ -f /etc/pd/sticky-digi ] || exit 0
/usr/local/sbin/digi-sticky-except-reload.sh
