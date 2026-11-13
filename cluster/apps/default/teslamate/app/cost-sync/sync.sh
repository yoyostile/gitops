#!/bin/sh
# Copies home-charging prices from evcc into TeslaMate's charging_processes.cost.
set -eu

sessions=$(mktemp)
trap 'rm -f "$sessions"' EXIT

if ! wget -qO "$sessions" -T 30 "$EVCC_URL"; then
  echo "fetching $EVCC_URL failed" >&2
  exit 1
fi

# The JSON goes in as a file, it outgrows a single argv entry.
# allocate.sql aborts on anything but a non-empty JSON array.
psql -X -q \
  -v sessions_file="$sessions" \
  -v net_price="${NET_PRICE:-0.2316}" \
  -v dry_run="${DRY_RUN:-0}" \
  -f "$(dirname "$0")/allocate.sql"
