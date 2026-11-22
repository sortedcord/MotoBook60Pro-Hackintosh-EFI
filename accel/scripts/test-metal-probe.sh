#!/bin/bash
# Run after XeGfx stage 7 as the logged-in user. The probe alone loads the private plugin.
set -euo pipefail

die() { echo "test-metal-probe: $*" >&2; exit 1; }
handoff=$(cd "$(dirname "$0")/.." && pwd)
plugin=/Library/XeGfx/metal/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver
[ "$(id -u)" != 0 ] || die "run as the logged-in user"
[ -r "$plugin" ] || die "cannot read $plugin"
case "${1:-}" in
  '') ;;
  --coredisplay) [ -f /Library/GPUBundles/nvmtl-gpupass-probe ] || die "enable the CoreDisplay probe flag first" ;;
  *) die "usage: $0 [--coredisplay]" ;;
esac

mkdir -p "$handoff/reports"
report=$(mktemp -d "$handoff/reports/metal-probe-$(date +%Y%m%d-%H%M%S)-XXXXXX")
echo "Reports: $report"
ioreg -l -w0 -r -c NMXAccel > "$report/ioreg-NMXAccel.txt"
grep -F 'class NMXAccel' "$report/ioreg-NMXAccel.txt" >/dev/null || die "stage 7 has not attached XeGfxAccel"

work=$(mktemp -d /private/tmp/nvmtl-probe.XXXXXX)
trap 'rm -rf "$work"' EXIT
mkdir "$work/aircache"
tar -xOzf "$handoff/downloads/WTLIntelGfx.tar.gz" ./userland/tools/mtlprobe.m > "$work/mtlprobe.m"
xcrun clang -fobjc-arc -O1 -mmacosx-version-min=15.0 -framework Foundation -framework Metal -framework IOKit \
  "$work/mtlprobe.m" -o "$work/mtlprobe" > "$report/build.txt" 2>&1 || die "compile failed; see $report/build.txt"
sync

rc=0
NM_TEST_PLUGIN="$plugin" NVMTL_LOG_PATH="$work/nvmtl.log" NVMTL_AIRCACHE="$work/aircache" \
  "$work/mtlprobe" 2>&1 | tee "$report/mtlprobe.txt" || rc=$?
if [ -f "$work/nvmtl.log" ]; then cp "$work/nvmtl.log" "$report/"; fi
sysctl -b debug.xegfx_log > "$report/xegfx-log.txt" 2>&1 || true
sync
[ "$rc" -eq 0 ] || exit "$rc"
grep -Fx 'metal compute: OK' "$report/mtlprobe.txt" >/dev/null || die "Metal compute did not pass"
grep -Fx 'metal draw: OK' "$report/mtlprobe.txt" >/dev/null || die "Metal draw did not pass"
if [ "${1:-}" = --coredisplay ]; then
  for pipeline in GPUPass ColorFill TextureCopy; do
    grep -F "ViewportToNDC + $pipeline -> *** PIPELINE BUILT ***" "$report/nvmtl.log" \
      || die "CoreDisplay's $pipeline pipeline did not build"
  done
fi
