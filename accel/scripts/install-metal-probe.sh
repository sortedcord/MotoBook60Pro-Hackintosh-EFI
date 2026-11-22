#!/bin/bash
# Install the private Metal probe stack after stages 1–6 have passed. Reboot before stage 7.
# The bundled framebuffer, AGDC, and XgFbMove kexts are for other bring-up steps.
# Auxiliary collection workflow adapted from samwu07/xegfx-thinkbook14plus-mtl (BSD-2-Clause).
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin

die() { echo "install-metal-probe: $*" >&2; exit 1; }
handoff=$(cd "$(dirname "$0")/.." && pwd)
archive="$handoff/downloads/xegfx-drivers-20261104-0140.zip"
archive_sha=9328416634741ada7fd8256235b366e83c090c9ab5201fa782fdfcc60b2b7a1c
extensions=/Library/Extensions
collection=/Library/KernelCollections/AuxiliaryKernelExtensions.kc
system_collections=/System/Library/KernelCollections
private=/Library/XeGfx
runtime=/Library/GPUBundles/nvmtl
kext="$extensions/XeGfxAccel.kext"
bundle_id=org.watchthelight.XeGfxAccel

[ "$(id -u)" = 0 ] || die "run with sudo"
[ "$(sw_vers -productVersion | cut -d. -f1)" = 15 ] || die "this Metal stack requires macOS 15"
[ "$(sysctl -n debug.xegfx_stage)" = 6 ] || die "complete XeGfx stage 6 first"
csrutil status | grep -E 'status: disabled|Kext Signing: disabled' >/dev/null || die "kext signing is enforced"
for path in "$private" "$runtime" "$kext" "$extensions/XeGfx.kext" /Library/GPUBundles/NVMTLDriver.bundle; do
  [ ! -e "$path" ] && [ ! -L "$path" ] || die "$path already exists; check the existing installation"
done

reports="$handoff/reports"
mkdir -p "$reports"
report=$(mktemp -d "$reports/metal-install-$(date +%Y%m%d-%H%M%S)-XXXXXX")
echo "Reports: $report"
work=$(mktemp -d /private/tmp/motobook-xegfx-install.XXXXXX)
next_collection=""
installed_private=0 installed_runtime=0 installed_kext=0 replaced_collection=0
cleanup() {
  rc=$?
  trap - EXIT
  if [ "$rc" -ne 0 ]; then
    echo "Metal install failed. Reports: $report" >&2
    if [ "$replaced_collection" = 1 ]; then
      if cp -p "$private/backup/AuxiliaryKernelExtensions.kc" "$next_collection" &&
         mv -f "$next_collection" "$collection" && kcditto >> "$report/rollback.log" 2>&1; then
        echo "Restored the original auxiliary collection."
      else
        echo "Automatic collection restore failed. Restore the backup in $report before rebooting." >&2
        exit "$rc"
      fi
    fi
    [ "$installed_kext" = 0 ] || rm -rf "$kext"
    [ "$installed_runtime" = 0 ] || rm -rf "$runtime"
    [ "$installed_private" = 0 ] || rm -rf "$private"
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
drivers="$work/xegfx-drivers"
plugin="$drivers/Library-GPUBundles/NVMTLDriver.bundle"
codesign --force --sign - "$plugin"
codesign --verify --deep --strict "$plugin"
codesign --verify --strict "$drivers/Library-Extensions/XeGfxAccel.kext"

mkdir -p "$work/private/metal" "$work/private/backup"
cp -p "$collection" "$work/private/backup/"
cp "$collection" "$report/"
cmp "$collection" "$report/AuxiliaryKernelExtensions.kc"
ditto --norsrc --noextattr "$plugin" "$work/private/metal/NVMTLDriver.bundle"
chmod -R u=rwX,go=rX "$work/private" "$drivers/Library-GPUBundles/nvmtl" "$drivers/Library-Extensions/XeGfxAccel.kext"
chown -R root:wheel "$work/private" "$drivers/Library-GPUBundles/nvmtl" "$drivers/Library-Extensions/XeGfxAccel.kext"
mv "$work/private" "$private"
installed_private=1
mv "$drivers/Library-GPUBundles/nvmtl" "$runtime"
installed_runtime=1
mv "$drivers/Library-Extensions/XeGfxAccel.kext" "$kext"
installed_kext=1
sync

kmutil inspect -a x86_64 -A "$collection" > "$report/previous-collection.txt"
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

next_collection=$(mktemp /Library/KernelCollections/.xegfx-probe.XXXXXX)
install -o root -g wheel -m 744 "$work/AuxiliaryKernelExtensions.kc" "$next_collection"
mv -f "$next_collection" "$collection"
replaced_collection=1
kcditto > "$report/kcditto.log" 2>&1 || die "could not sync the auxiliary collection to Preboot"
sync
echo "Private Metal stack installed. Reboot through OpenCore, then run XeGfx stage 7."
