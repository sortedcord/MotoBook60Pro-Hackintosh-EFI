#!/bin/bash
# Compare copied presentation against zero-copy flips while the user repeats the same window drag.
# Zero-copy stays ON afterwards: the earlier crash came about 2 s after switching it back off under load,
# so this test never turns it off. A reboot clears it. Pass --off only with the desktop idle.
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin

die() { echo "test-zero-copy: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run with sudo"
handoff=$(cd "$(dirname "$0")/.." && pwd)
if [ "${1:-}" = --off ]; then
  sysctl -w debug.nvaccel_xeflip=0; sync; exit 0
fi
[ "$(sysctl -n debug.nvaccelfb)" = 1 ] || die "XeGfx desktop acceleration must be active (run desktop-on.sh first)"
[ "$(sysctl -n debug.nvaccel_iop)" = 1 ] || die "display-pipe transactions must be enabled"
[ "$(sysctl -n debug.nvaccel_xeflip)" = 0 ] || die "zero-copy is already on"
windowserver=$(pgrep -xo WindowServer) || die "cannot find WindowServer"

report=$(mktemp -d "$handoff/reports/zero-copy-$(date +%Y%m%d-%H%M%S)-XXXXXX")
echo "Reports: $report"
keys=(debug.nvaccel_iop_ok debug.nvaccel_iop_ok_h4 debug.nvaccel_iop_fail debug.nvaccel_iop_flips
      debug.nvaccel_xeflip_flips debug.nvaccel_xeflip_copied debug.nvaccel_xeflip_kept
      debug.nvaccel_iop_flip_miss debug.nvaccel_iop_flip_refused debug.nvaccel_iop_vbl_miss
      debug.nvaccel_surface_gpu_timeouts)
sysctl debug.nvaccel_iop_vblsync debug.nvaccel_iop_async debug.nvaccel_xeflip_idle_ms "${keys[@]}" > "$report/before.txt"

snap() { local k; for k in "${keys[@]}"; do printf '%s ' "$(sysctl -n "$k")"; done; }
header=$(printf '%s\t' time phase "${keys[@]#debug.nvaccel_}")
printf '%s\n' "${header%$'\t'}" > "$report/deltas.tsv"
sample_phase() {
  local phase=$1 prev cur i
  prev=($(snap))
  for _ in {1..10}; do
    sleep 1
    cur=($(snap))
    line="$(date +%T)"$'\t'"$phase"
    for i in "${!keys[@]}"; do line+=$'\t'$((cur[i] - prev[i])); done
    printf '%s\n' "$line" >> "$report/deltas.tsv"
    prev=("${cur[@]}")
  done
}

echo "Keep dragging one window in circles for about 25 seconds, starting now."
sync
sleep 2
sample_phase copy
sysctl -w debug.nvaccel_xeflip=1 > "$report/xeflip-on.txt"
sync
sleep 1
sysctl debug.nvaccel_xeflip_ggtt >> "$report/xeflip-on.txt" 2>&1 || true
sample_phase zero-copy
sysctl "${keys[@]}" debug.nvaccel_xeflip debug.nvaccel_xeflip_last_why > "$report/after.txt"
[ "$(pgrep -xo WindowServer)" = "$windowserver" ] || echo "WARNING: WindowServer restarted during the test" | tee -a "$report/after.txt"
sync
awk -F '\t' 'NR == 1 { for (i = 3; i <= NF; i++) name[i] = $i; next }
  { n[$2]++; for (i = 3; i <= NF; i++) sum[$2, i] += $i }
  END { for (p in n) { printf "%s:", p; for (i = 3; i <= 13; i++) if (sum[p, i]) printf " %s=%.1f/s", name[i], sum[p, i] / n[p]; print "" } }' \
  "$report/deltas.tsv" | tee "$report/summary.txt"
echo "Zero-copy is still ON. Tell Claude whether the drag looks smoother and whether tearing is gone."
