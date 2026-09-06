#!/usr/bin/env bash
# Take a screenshot on the MiSTer via the MiSTer Remote (mrext) HTTP API and
# download it.   scripts/screenshot.sh [out.png]
set -eu
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -r scripts/local.env ] && . scripts/local.env
HOST="${MISTER_HOST:-192.168.99.92}"
PORT="${MISTER_HTTP_PORT:-8182}"
OUT="${1:-docs/screenshot.png}"
API="http://$HOST:$PORT/api/screenshots"

curl -s -X POST "$API" >/dev/null
sleep 2
ENC=$(curl -s "$API" | python3 -c "import sys,json,urllib.parse as u;d=json.load(sys.stdin);d.sort(key=lambda x:x['modified']);print(u.quote(d[-1]['path']))")
mkdir -p "$(dirname "$OUT")"
curl -s -o "$OUT" "$API/$ENC"
echo "$OUT <- $ENC ($(stat -c %s "$OUT") bytes)"
