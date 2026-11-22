#!/bin/bash
# collect-baseline.sh -- HANDOFF.md gate 0: record the macOS state before any XeGfx step. Read-only.
#   sudo bash collect-baseline.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
[ "$(id -u)" = 0 ] || { echo "run with sudo:  sudo bash $0" >&2; exit 2; }
OUT="$(cd "$HERE/.." && pwd)/reports/baseline-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$OUT"
{ sw_vers; uname -a; sysctl -n kern.bootargs machdep.cpu.brand_string hw.ncpu hw.memsize; csrutil status
  csrutil authenticated-root status 2>&1; nvram csr-active-config 2>&1; } > "$OUT/system.txt" 2>&1
kmutil showloaded --list-only 2>/dev/null | grep -v com.apple > "$OUT/kexts-thirdparty.txt"
kmutil showloaded --list-only > "$OUT/kexts-all.txt" 2>&1
ioreg -l -w0 -r -n GFX0 > "$OUT/ioreg-GFX0.txt" 2>&1
ioreg -l -w0 -r -c IOFramebuffer > "$OUT/ioreg-IOFramebuffer.txt" 2>&1
ioreg -l -w0 -r -c IODisplayConnect > "$OUT/ioreg-IODisplayConnect.txt" 2>&1
ioreg -l -w0 -p IODeviceTree -n PNLF > "$OUT/ioreg-PNLF.txt" 2>&1
system_profiler SPDisplaysDataType SPHardwareDataType SPAudioDataType SPBluetoothDataType SPUSBDataType SPPCIDataType SPPowerDataType > "$OUT/system_profiler.txt" 2>&1
ioreg -l -w0 -r -c IOPCIDevice | grep -E '"(device-id|vendor-id|IOName|pcidebug)"' > "$OUT/pci-summary.txt" 2>&1
pmset -g > "$OUT/pmset.txt" 2>&1; pmset -g assertions >> "$OUT/pmset.txt" 2>&1
log show --last boot --style compact --predicate 'process == "kernel"' 2>/dev/null | grep -iE 'panic|UEFIGraphicsFB|framebuffer|GFX0|AppleALC|VoodooI2C|VoodooPS2|USBToolBox|AirPort_RTW89|Bluetooth' | tail -400 > "$OUT/kernel-boot-filtered.txt"
ls /Library/Extensions /Library/GPUBundles 2>/dev/null > "$OUT/library-ext.txt"
ls -la /Library/KernelCollections/ >> "$OUT/library-ext.txt" 2>&1
xcode-select -p > "$OUT/xcode-select.txt" 2>&1
sync
echo "baseline saved in $OUT"
