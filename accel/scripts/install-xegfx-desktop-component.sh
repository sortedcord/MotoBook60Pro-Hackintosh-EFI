#!/bin/bash
# Prepare one XeGfx desktop component for the next boot after the private Metal probe passes.
# Auxiliary collection workflow adapted from samwu07/xegfx-thinkbook14plus-mtl (BSD-2-Clause).
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin

die() { echo "install-xegfx-desktop-component: $*" >&2; exit 1; }
handoff=$(cd "$(dirname "$0")/.." && pwd)
archive="$handoff/downloads/xegfx-drivers-20261104-0140.zip"
archive_sha=9328416634741ada7fd8256235b366e83c090c9ab5201fa782fdfcc60b2b7a1c
extensions=/Library/Extensions
collection=/Library/KernelCollections/AuxiliaryKernelExtensions.kc
system_collections=/System/Library/KernelCollections
component=${1:-}
case "$component" in
  framebuffer) bundle=XeGfxIntelFB ;;
  compositor) bundle=XeGfxAGDC ;;
  *) die "usage: $0 framebuffer | compositor COREDISPLAY_REPORT" ;;
esac
kext="$extensions/$bundle.kext"
bundle_id="org.watchthelight.$bundle"
match_key=IOKitPersonalities.XeGfxIntelFramebuffer.IOPCIMatch
gpu=/Library/GPUBundles
plugin="$gpu/NVMTLDriver.bundle"
allowlist="$gpu/nvmtl-allow.txt"

[ "$(id -u)" = 0 ] || die "run with sudo"
[ "$(sysctl -n debug.xegfx_stage)" = 7 ] || die "complete XeGfx stage 7 first"
ioreg -l -w0 -r -n GFX0 | grep -F '"device-id" = <517d0000>' >/dev/null || die "expected Arc 130T (7D51)"
for path in "$kext" "$extensions/NMIntelFB.kext"; do
  [ ! -e "$path" ] && [ ! -L "$path" ] || die "$path already exists; check the installed kexts"
done
if [ "$component" = compositor ]; then
  ioreg -r -c XeGfxIntelFramebuffer -d 2 | grep -F display0 >/dev/null || die "the panel must use XeGfxIntelFramebuffer"
  for path in "$plugin" "$allowlist"; do
    [ ! -e "$path" ] && [ ! -L "$path" ] || die "$path already exists; check the existing plugin configuration"
  done
  for pipeline in GPUPass ColorFill TextureCopy; do
    grep -F "ViewportToNDC + $pipeline -> *** PIPELINE BUILT ***" "${2:-}/nvmtl.log" >/dev/null \
      || die "provide the private probe report with all three CoreDisplay pipelines passing"
  done
fi

report=$(mktemp -d "$handoff/reports/$component-install-$(date +%Y%m%d-%H%M%S)-XXXXXX")
echo "Reports: $report"
backup=$(mktemp -d "/Library/XeGfx/backup-$component-XXXXXX")
work=$(mktemp -d /private/tmp/motobook-xegfx-desktop.XXXXXX)
next_collection=""
installed_kext=0 replaced_collection=0 installed_plugin=0 installed_allowlist=0
cleanup() {
  rc=$?
  trap - EXIT
  if [ "$rc" -ne 0 ]; then
    echo "$bundle install failed. Reports: $report" >&2
    [ "$installed_allowlist" = 0 ] || rm -f "$allowlist"
    [ "$installed_plugin" = 0 ] || rm -rf "$plugin"
    if [ "$replaced_collection" = 1 ]; then
      if cp -p "$backup/AuxiliaryKernelExtensions.kc" "$next_collection" &&
         mv -f "$next_collection" "$collection" && kcditto >> "$report/rollback.log" 2>&1; then
        echo "Restored the previous auxiliary collection."
      else
        echo "Automatic collection restore failed. Restore the backup in $report before rebooting." >&2
        exit "$rc"
      fi
    fi
    [ "$installed_kext" = 0 ] || rm -rf "$kext"
  fi
  [ -z "$next_collection" ] || rm -f "$next_collection"
  rm -rf "$work"
  sync
  exit "$rc"
}
trap cleanup EXIT

cp "$archive" "$work/drivers.zip"
printf '%s  %s\n' "$archive_sha" "$work/drivers.zip" | shasum -a 256 -c
ditto -x -k "$work/drivers.zip" "$work"
staged="$work/xegfx-drivers/Library-Extensions/$bundle.kext"
if [ "$component" = framebuffer ]; then
  plist="$staged/Contents/Info.plist"
  match=$(plutil -extract "$match_key" raw -o - "$plist")
  plutil -replace "$match_key" -string "$match 0x7d518086" "$plist"
  plutil -extract "$match_key" raw -o - "$plist" > "$report/pci-match.txt"
else
  ditto --norsrc --noextattr /Library/XeGfx/metal/NVMTLDriver.bundle "$work/NVMTLDriver.bundle"
  codesign --verify --deep --strict "$work/NVMTLDriver.bundle"
  printf '!WindowServer\n' > "$work/nvmtl-allow.txt"
  chmod 644 "$work/nvmtl-allow.txt"
  chown root:wheel "$work/nvmtl-allow.txt"
fi
codesign --force --sign - "$staged"
codesign --verify --deep --strict "$staged"
chmod -R u=rwX,go=rX "$staged"
chown -R root:wheel "$staged"

cp -p "$collection" "$backup/"
cp "$collection" "$report/"
cmp "$backup/AuxiliaryKernelExtensions.kc" "$report/AuxiliaryKernelExtensions.kc"
kmutil inspect -a x86_64 -A "$collection" > "$report/previous-collection.txt"
mv "$staged" "$kext"
installed_kext=1
sync

kmutil create -a x86_64 -n aux --volume-root / --allow-missing-kdk --kernel /System/Library/Kernels/kernel \
  -B "$system_collections/BootKernelExtensions.kc" -S "$system_collections/SystemKernelExtensions.kc" \
  --repository "$extensions" --repository /Library/Apple/System/Library/Extensions \
  --bundle-identifier "$bundle_id" -A "$work/AuxiliaryKernelExtensions.kc" --no-authorization \
  > "$report/kmutil.log" 2>&1 || die "kernel collection failed to link; see $report/kmutil.log"
kmutil inspect -a x86_64 -A "$work/AuxiliaryKernelExtensions.kc" > "$report/new-collection.txt"
old_ids=$(awk -F '\t' 'NF >= 3 {print $1}' "$report/previous-collection.txt")
new_ids=$(awk -F '\t' 'NF >= 3 {print $1}' "$report/new-collection.txt")
for identifier in $old_ids "$bundle_id"; do
  grep -Fx "$identifier" <<< "$new_ids" >/dev/null || die "$identifier is missing from the new collection"
done

next_collection=$(mktemp /Library/KernelCollections/.xegfx-desktop.XXXXXX)
install -o root -g wheel -m 744 "$work/AuxiliaryKernelExtensions.kc" "$next_collection"
mv -f "$next_collection" "$collection"
replaced_collection=1
kcditto > "$report/kcditto.log" 2>&1 || die "could not sync the auxiliary collection to Preboot"
if [ "$component" = compositor ]; then
  mv "$work/nvmtl-allow.txt" "$allowlist"
  installed_allowlist=1
  mv "$work/NVMTLDriver.bundle" "$plugin"
  installed_plugin=1
fi
sync
echo "$bundle installed. Reboot through OpenCore before testing it."
echo "Previous collection: $backup/AuxiliaryKernelExtensions.kc"
