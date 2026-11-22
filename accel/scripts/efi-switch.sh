#!/bin/bash
# efi-switch.sh safe|xegfx|status [ESP]  -- choose which config.plist OpenCore boots next.
#   safe   = XEGFX-HANDOFF/efi/config-safe.plist  (the working UEFIGraphicsFB config)
#   xegfx  = XEGFX-HANDOFF/efi/config-xegfx.plist (+ XeGfx 0.0.48 via Kernel/Add, idle until loaded)
# ESP defaults to /Volumes/OPENCORE (macOS) or /mnt/oc (Linux). The current config.plist is backed up first.
set -euo pipefail
MODE=${1:-status}
ESP=${2:-}
if [ -z "$ESP" ]; then
  for c in /Volumes/OPENCORE /mnt/oc /mnt; do [ -f "$c/EFI/OC/config.plist" ] && ESP=$c && break; done
fi
[ -n "$ESP" ] && [ -f "$ESP/EFI/OC/config.plist" ] || {
  echo "ESP not mounted. macOS: sudo diskutil mount \$(diskutil list external | awk '/OPENCORE/{print \$NF}')" >&2
  echo "Linux: sudo mount /dev/sda1 /mnt/oc" >&2; exit 2; }
H="$ESP/XEGFX-HANDOFF/efi"; CFG="$ESP/EFI/OC/config.plist"
sum() { shasum -a 256 "$1" 2>/dev/null | cut -c1-16 || sha256sum "$1" | cut -c1-16; }
case "$MODE" in
  status)
    cur=$(sum "$CFG")
    for n in safe xegfx; do [ "$(sum "$H/config-$n.plist")" = "$cur" ] && { echo "config.plist = config-$n.plist ($cur)"; exit 0; }; done
    echo "config.plist ($cur) matches neither config-safe nor config-xegfx (edited by hand?)"; exit 0 ;;
  safe|xegfx)
    [ -f "$H/config-$MODE.plist" ] || { echo "missing $H/config-$MODE.plist" >&2; exit 1; }
    if [ "$MODE" = xegfx ] && [ ! -f "$ESP/EFI/OC/Kexts/XeGfx.kext/Contents/MacOS/XeGfx" ]; then
      echo "EFI/OC/Kexts/XeGfx.kext missing: unzip downloads/XeGfx-0.0.48.zip into EFI/OC/Kexts first" >&2; exit 1
    fi
    mkdir -p "$H/backups"
    cp "$CFG" "$H/backups/config-$(date +%Y%m%d-%H%M%S).plist"
    cp "$H/config-$MODE.plist" "$CFG"
    sync
    echo "next boot uses config-$MODE.plist ($(sum "$CFG")); previous saved in $H/backups/" ;;
  *) echo "usage: $0 safe|xegfx|status [ESP]" >&2; exit 2 ;;
esac
