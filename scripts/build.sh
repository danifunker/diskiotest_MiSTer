#!/usr/bin/env bash
# Compile DiskIOTest with Quartus 17.0 and copy the rbf into releases/.
#   scripts/build.sh          16-bit hps_io bus (revision DiskIOTest)
#   scripts/build.sh 8        8-bit hps_io bus  (revision DiskIOTest_8bit)
#   scripts/build.sh all      both, one after the other
# Machine settings (QUARTUS_BIN, ...) come from scripts/local.env if present.
set -u
case "${1:-16}" in
	8)   REVS="DiskIOTest_8bit" ;;
	all) REVS="DiskIOTest DiskIOTest_8bit" ;;
	*)   REVS="DiskIOTest" ;;
esac
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
[ -r scripts/local.env ] && . scripts/local.env
QUARTUS_BIN="${QUARTUS_BIN:-$HOME/intelFPGA_lite/17.0/quartus/bin}"
export PATH="$QUARTUS_BIN:$PATH"

mkdir -p output_files releases
RC=0
for REV in $REVS; do
	LOG="output_files/compile_${REV}_$(date +%Y%m%d_%H%M%S).log"
	echo "[$(date +%T)] quartus_sh --flow compile DiskIOTest -c $REV" | tee "$LOG"
	quartus_sh --flow compile DiskIOTest -c "$REV" 2>&1 | tee -a "$LOG"
	RC=${PIPESTATUS[0]}
	echo "[$(date +%T)] compile $REV exit=$RC" | tee -a "$LOG"
	[ "$RC" -eq 0 ] || break
	if [ -f "output_files/$REV.rbf" ]; then
		cp "output_files/$REV.rbf" "releases/${REV}_$(date +%Y%m%d).rbf"
		grep -h "Fitter Status\|Logic utilization\|Total block memory" "output_files/$REV.fit.summary" 2>/dev/null
	fi
done
ls -la releases/
exit "$RC"
