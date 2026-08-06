#!/bin/bash
# Reload Digi sticky exception whitelist without tearing hairpin/NAT.
# Edit /etc/pd/digi-sticky-except.conf then run this.
set -euo pipefail
exec /usr/local/sbin/digi-sticky-outbound.sh --reload-except
