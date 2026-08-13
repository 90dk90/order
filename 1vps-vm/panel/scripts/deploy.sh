#!/usr/bin/env bash
# Deploy 1vps-vm agent/host bits + panel drop-ins.
# Run from repo: ./panel/scripts/deploy.sh
# Or copy pieces manually (see README).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
echo "repo=$ROOT"
echo "This script is a checklist runner for the cloud agent; prefer SSH deploy steps in docs."
ls -la "$ROOT/agent" "$ROOT/host" "$ROOT/panel"
