#!/bin/bash
# XeGfxAccel 0.9.6d1 tear diagnostics, with the GPU desktop up (desktop-on.sh) and the user dragging one window.
# Three 15 s phases: pre-flip clflush off, on, off. Counts WindowServer drawing into the surface on the panel
# (front_draws) and times the flush. Turns zero-copy on if needed and leaves it on; the flush ends off.
# Also restores the normal OpenCore config on disk if the AMFI test config is still live.
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin

die() { echo "test-tear-diag: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run with sudo"
handoff=$(cd "$(dirname "$0")/.." && pwd)
live="$handoff/../EFI/OC/config.plist"
if [ -f "$live" ] && cmp -s "$live" "$handoff/efi/config-xegfx-amfi-test.plist"; then
  cp "$handoff/efi/config-xegfx.plist" "$live" && sync && cmp "$live" "$handoff/efi/config-xegfx.plist"
  echo "Restored the normal OpenCore config on disk (this boot keeps amfi=0x80)."
fi
sysctl debug.nvaccel_xeflip_front_draws > /dev/null 2>&1 || die "XeGfxAccel 0.9.6d1 is not loaded (install it, reboot, run stages 1-7)"
[ "$(sysctl -n debug.nvaccelfb)" = 1 ] || die "XeGfx desktop acceleration must be active (run desktop-on.sh first)"
windowserver=$(pgrep -xo WindowServer) || die "cannot find WindowServer"

report=$(mktemp -d "$handoff/reports/tear-diag-$(date +%Y%m%d-%H%M%S)-XXXXXX")
echo "Reports: $report"
trap 'sysctl -w debug.nvaccel_xeflip_clflush=0 >/dev/null 2>&1 || true; sync' EXIT
if [ "$(sysctl -n debug.nvaccel_xeflip)" = 0 ]; then
  sysctl -w debug.nvaccel_xeflip=1 > "$report/xeflip-on.txt"
  sleep 1
fi
keys=(debug.nvaccel_xeflip_flips debug.nvaccel_xeflip_front_draws debug.nvaccel_xeflip_pend_marks
      debug.nvaccel_xeflip_flushes debug.nvaccel_xeflip_copied debug.nvaccel_surface_gpu_timeouts debug.nvaccel_iop_fail)
sysctl "${keys[@]}" debug.nvaccel_xeflip debug.nvaccel_iop_vblsync > "$report/before.txt"
snap() { local k; for k in "${keys[@]}"; do printf '%s ' "$(sysctl -n "$k")"; done; }
header=$(printf '%s\t' time phase "${keys[@]#debug.nvaccel_}" clflush_us)
printf '%s\n' "${header%$'\t'}" > "$report/deltas.tsv"
phase() {
  local name=$1 prev cur i line
  echo ">>> $(date +%T) phase: $name (15 s) -- keep dragging and watch for tearing"
  prev=($(snap))
  for _ in {1..15}; do
    sleep 1
    cur=($(snap))
    line="$(date +%T)"$'\t'"$name"
    for i in "${!keys[@]}"; do line+=$'\t'$((cur[i] - prev[i])); done
    printf '%s\t%s\n' "$line" "$(sysctl -n debug.nvaccel_xeflip_clflush_us)" >> "$report/deltas.tsv"
    prev=("${cur[@]}")
  done
  sync
}
echo "Start dragging one window in circles now."
sleep 3
phase flush-off
sysctl -w debug.nvaccel_xeflip_clflush=1 > /dev/null
phase flush-on
sysctl -w debug.nvaccel_xeflip_clflush=0 > /dev/null
phase flush-off-again
sysctl "${keys[@]}" debug.nvaccel_xeflip_clflush_us_max debug.nvaccel_xeflip debug.nvaccel_xeflip_last_why > "$report/after.txt"
[ "$(pgrep -xo WindowServer)" = "$windowserver" ] || echo "WARNING: WindowServer restarted during the test" | tee -a "$report/after.txt"
awk -F '\t' 'NR == 1 { for (i = 3; i <= NF; i++) name[i] = $i; next }
  { if (!($2 in n)) order[++np] = $2; n[$2]++; for (i = 3; i <= NF; i++) sum[$2, i] += $i }
  END { for (j = 1; j <= np; j++) { p = order[j]; printf "%-15s", p ":";
        for (i = 3; i < NF; i++) printf " %s=%.1f/s", name[i], sum[p, i] / n[p];
        printf " avg_flush_us=%.0f\n", sum[p, NF] / n[p] } }' "$report/deltas.tsv" | tee "$report/summary.txt"
echo "Tell Claude in which phase (off / on / off again) the tearing was gone or reduced."
