#!/usr/bin/env bash
# Push the rbf to the MiSTer, make sure a scratch image exists, pre-write the
# per-slot mount memory so the image auto-mounts, and load the core.
#
#   scripts/deploy.sh [path/to/DiskIOTest_16bit.rbf | path/to/DiskIOTest_8bit.rbf]
#
# Settings (scripts/local.env or environment): MISTER_HOST, MISTER_SSH_KEY,
# IMG_MB (scratch image size, default 1024).
set -eu
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -r scripts/local.env ] && . scripts/local.env
HOST="${MISTER_HOST:-192.168.99.92}"
KEY="${MISTER_SSH_KEY:-}"
IMG_MB="${IMG_MB:-1024}"
RBF="${1:-output_files/DiskIOTest_16bit.rbf}"

SSH="ssh -o BatchMode=yes ${KEY:+-i $KEY} root@$HOST"
SCP="scp -o BatchMode=yes ${KEY:+-i $KEY}"
BASE="$(basename "$RBF" .rbf)"
BASE="${BASE%_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]}"   # strip a date code if present
REMOTE_RBF="/media/fat/_Utility/${BASE}_$(date +%Y%m%d).rbf"
IMG_REL="games/DiskIOTest/scratch_${IMG_MB}M.img"

[ -f "$RBF" ] || { echo "no rbf at $RBF"; exit 1; }
echo "pushing $RBF -> $HOST:$REMOTE_RBF"
$SCP "$RBF" "root@$HOST:$REMOTE_RBF.tmp"
$SSH "set -e
mv -f '$REMOTE_RBF.tmp' '$REMOTE_RBF'
for f in /media/fat/_Utility/${BASE}_????????.rbf; do [ \"\$f\" = '$REMOTE_RBF' ] || rm -f \"\$f\"; done
mkdir -p /media/fat/games/DiskIOTest
if [ ! -f '/media/fat/$IMG_REL' ]; then
	echo 'creating ${IMG_MB} MB scratch image (fully written, not sparse)'
	dd if=/dev/zero of='/media/fat/$IMG_REL' bs=1M count=$IMG_MB 2>&1 | tail -1
	sync
fi
printf '%s' '$IMG_REL' | dd of=/media/fat/config/DiskIOTest.s0 bs=1024 count=1 conv=sync 2>/dev/null
echo 'load_core $REMOTE_RBF' > /dev/MiSTer_cmd
echo 'loaded $REMOTE_RBF with $IMG_REL'"
