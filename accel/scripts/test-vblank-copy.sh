#!/bin/bash
# Compare synchronized and immediate copies while the user repeats the same window drag.
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin

die() { echo "test-vblank-copy: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run with sudo"
handoff=$(cd "$(dirname "$0")/.." && pwd)
reports=${1:-$handoff/reports}
key=debug.nvaccel_iop_vblsync
frames=debug.nvaccel_iop_ok_h4
[ "$(sysctl -n debug.nvaccel_xeflip)" = 0 ] || die "zero-copy must be off"
[ "$(sysctl -n debug.nvaccelfb)" = 1 ] || die "XeGfx desktop acceleration must be active"
[ "$(sysctl -n "$key")" = 1 ] || die "start with vertical blank synchronization enabled"
windowserver=$(pgrep -xo WindowServer) || die "cannot find WindowServer"

mkdir -p "$reports"
report=$(mktemp -d "$reports/vblank-copy-timing-$(date +%Y%m%d-%H%M%S)-XXXXXX")
echo "Reports: $report"

restore() {
  sysctl -w "$key=1" >> "$report/restore.txt" 2>&1
  sync
}
trap restore EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

sample_phase() {
  local mode=$1 first last wait sample
  sleep 1
  first=$(sysctl -n "$frames")
  for sample in {1..10}; do
    sleep 1
    last=$(sysctl -n "$frames")
    wait=NA
    if [ "$mode" != immediate ]; then wait=$(sysctl -n debug.nvaccel_iop_vbl_wait_us); fi
    printf '%s\t%s\t%d\t%s\n' "$(date +%T)" "$mode" "$((last - first))" "$wait" >> "$report/timing.tsv"
    first=$last
  done
}

printf 'time\tmode\tframes_in_sample\tlast_vblank_wait_us\n' > "$report/timing.tsv"
sync
sample_phase synced
(
  trap - EXIT
  trap '' HUP
  sleep 14
  restore
) </dev/null > "$report/fallback.txt" 2>&1 &
disown
sysctl -w "$key=0" > "$report/immediate.txt"
sample_phase immediate
restore
sample_phase synced-again
[ "$(pgrep -xo WindowServer)" = "$windowserver" ] || die "WindowServer restarted during the test"
sysctl "$key" debug.nvaccel_xeflip debug.nvaccel_iop_fail > "$report/after.txt"
awk -F '\t' 'NR > 1 { total[$2] += $3; count[$2]++ } END {
  printf "Synced %.1f, immediate %.1f, synced again %.1f frames/sample\n", total["synced"]/count["synced"],
    total["immediate"]/count["immediate"], total["synced-again"]/count["synced-again"]
}' "$report/timing.tsv" | tee "$report/summary.txt"
