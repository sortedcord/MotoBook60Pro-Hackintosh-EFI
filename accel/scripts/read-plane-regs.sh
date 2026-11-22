#!/bin/bash
# Read-only: dump pipe A plane 1 registers through XeGfxAccel's MMIO window, then restore the window address.
# Answers whether PLANE_CTL has async address update (bit 9) set, which makes PLANE_SURF writes skip the vblank latch.
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
handoff=$(cd "$(dirname "$0")/.." && pwd)
out="$handoff/reports/plane-regs-$(date +%Y%m%d-%H%M%S).txt"
old=$(sysctl -n debug.nvaccel_mmio_addr)
trap 'sysctl -w debug.nvaccel_mmio_addr=$old >/dev/null' EXIT
reg() {   # $1 = offset from 0x70180; little-endian 32-bit word from the hex dump
  local h=${dump:$(( $1 * 2 )):8}
  printf '0x%s%s%s%s' "${h:6:2}" "${h:4:2}" "${h:2:2}" "${h:0:2}"
}
sysctl -w debug.nvaccel_mmio_addr=$((0x70180)) >/dev/null
{
  for n in 1 2 3; do
    dump=$(sysctl -x debug.nvaccel_mmio_win | sed 's/.*Dump:0x//')
    ctl=$(reg 0x00)
    echo "sample $n: PLANE_CTL=$ctl STRIDE=$(reg 0x08) SIZE=$(reg 0x10) SURF=$(reg 0x1c) SURFLIVE=$(reg 0x2c)"
    echo "  enable=$(( (ctl >> 31) & 1 )) async_address_update(bit9)=$(( (ctl >> 9) & 1 )) tiling(bits12-14)=$(( (ctl >> 12) & 7 )) format(bits23-27)=$(( (ctl >> 23) & 31 ))"
    sleep 0.2
  done
  sysctl debug.nvaccel_xeflip debug.nvaccel_xeflip_flips debug.nvaccel_surface_gpu_timeouts
} | tee "$out"
sync
echo "Saved $out"
