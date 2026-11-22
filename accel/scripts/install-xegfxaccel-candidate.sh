#!/bin/bash
# Replace the installed XeGfxAccel.kext with a candidate build from the handoff and relink the auxiliary collection.
#   sudo bash install-xegfxaccel-candidate.sh candidates/xegfxaccel-teardiag-0.9.6d1/XeGfxAccel.kext
#   sudo bash install-xegfxaccel-candidate.sh --restore /Library/XeGfx/backup-xegfxaccel-XXXXXX
# Reboot through OpenCore afterwards. Auxiliary collection workflow adapted from samwu07/xegfx-thinkbook14plus-mtl.
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin

die() { echo "install-xegfxaccel-candidate: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run with sudo"
[ "$(sw_vers -productVersion | cut -d. -f1)" = 15 ] || die "these builds are for macOS 15"
handoff=$(cd "$(dirname "$0")/.." && pwd)
extensions=/Library/Extensions
kext="$extensions/XeGfxAccel.kext"
bundle_id=org.watchthelight.XeGfxAccel
collection=/Library/KernelCollections/AuxiliaryKernelExtensions.kc
system_collections=/System/Library/KernelCollections

if [ "${1:-}" = --restore ]; then
  from=${2:-}
  [ -f "$from/AuxiliaryKernelExtensions.kc" ] && [ -d "$from/XeGfxAccel.kext" ] || die "usage: --restore BACKUP_DIR"
  rm -rf "$kext"
  ditto --norsrc --noextattr "$from/XeGfxAccel.kext" "$kext"
  install -o root -g wheel -m 744 "$from/AuxiliaryKernelExtensions.kc" "$collection.restore"
  mv -f "$collection.restore" "$collection"
  kcditto
  sync
  echo "Restored XeGfxAccel and the auxiliary collection from $from. Reboot through OpenCore."
  exit 0
fi

source=${1:-}
case "$source" in /*) ;; *) source="$handoff/$source" ;; esac
[ -f "$source/Contents/Info.plist" ] || die "usage: $0 CANDIDATE/XeGfxAccel.kext"
candidate_dir=$(dirname "$source")
if [ -f "$candidate_dir/SHA256SUMS" ]; then
  (cd "$candidate_dir" && shasum -a 256 -c SHA256SUMS --quiet) || die "files in $candidate_dir changed (SHA256SUMS)"
fi
[ "$(plutil -extract CFBundleIdentifier raw -o - "$source/Contents/Info.plist")" = "$bundle_id" ] || die "not XeGfxAccel"
version=$(plutil -extract CFBundleVersion raw -o - "$source/Contents/Info.plist")
[ -d "$kext" ] || die "XeGfxAccel is not installed; this only replaces it"
current=$(plutil -extract CFBundleVersion raw -o - "$kext/Contents/Info.plist")
echo "XeGfxAccel $current -> $version"

report=$(mktemp -d "$handoff/reports/xegfxaccel-install-$(date +%Y%m%d-%H%M%S)-XXXXXX")
echo "Reports: $report"
exec > >(tee "$report/install.log") 2>&1
mkdir -p /Library/XeGfx
backup=$(mktemp -d /Library/XeGfx/backup-xegfxaccel-XXXXXX)
work=$(mktemp -d /private/tmp/motobook-xegfxaccel.XXXXXX)
swapped=0 replaced=0 next_collection=""
cleanup() {
  rc=$?
  trap - EXIT
  if [ "$rc" -ne 0 ]; then
    if [ "$replaced" = 1 ]; then
      install -o root -g wheel -m 744 "$backup/AuxiliaryKernelExtensions.kc" "$collection.rollback" &&
        mv -f "$collection.rollback" "$collection" && kcditto >> "$report/rollback.log" 2>&1 ||
        echo "Collection rollback failed: restore $backup before rebooting" >&2
    fi
    if [ "$swapped" = 1 ]; then rm -rf "$kext"; ditto --norsrc --noextattr "$backup/XeGfxAccel.kext" "$kext"; fi
    echo "Install failed; the previous XeGfxAccel and collection are in place. Reports: $report" >&2
  fi
  [ -z "$next_collection" ] || rm -f "$next_collection"
  rm -rf "$work"
  sync
  exit "$rc"
}
trap cleanup EXIT

cp -p "$collection" "$backup/"
ditto --norsrc --noextattr "$kext" "$backup/XeGfxAccel.kext"
cmp "$collection" "$backup/AuxiliaryKernelExtensions.kc"
printf '%s\n' "$backup" > "$report/backup-path.txt"
kmutil inspect -a x86_64 -A "$collection" > "$report/previous-collection.txt"

ditto --norsrc --noextattr "$source" "$work/XeGfxAccel.kext"
find "$work/XeGfxAccel.kext" -name '._*' -delete
codesign --verify --strict "$work/XeGfxAccel.kext"
chown -R root:wheel "$work/XeGfxAccel.kext"
chmod -R u=rwX,go=rX "$work/XeGfxAccel.kext"
rm -rf "$kext"
mv "$work/XeGfxAccel.kext" "$kext"
swapped=1
sync

repos=(--repository "$extensions")
[ -d /Library/Apple/System/Library/Extensions ] && repos+=(--repository /Library/Apple/System/Library/Extensions)
kmutil create -a x86_64 -n aux --volume-root / --allow-missing-kdk --kernel /System/Library/Kernels/kernel \
  -B "$system_collections/BootKernelExtensions.kc" -S "$system_collections/SystemKernelExtensions.kc" \
  "${repos[@]}" -A "$work/AuxiliaryKernelExtensions.kc" --no-authorization \
  > "$report/kmutil.log" 2>&1 || die "kernel collection failed to link; see $report/kmutil.log"
kmutil inspect -a x86_64 -A "$work/AuxiliaryKernelExtensions.kc" > "$report/new-collection.txt"
for identifier in $(awk -F '\t' 'NF >= 3 {print $1}' "$report/previous-collection.txt"); do
  awk -F '\t' -v id="$identifier" '$1 == id {f=1} END {exit !f}' "$report/new-collection.txt" \
    || die "$identifier is missing from the new collection"
done
awk -F '\t' -v id="$bundle_id" -v v="$version" '$1 == id && $2 == v {f=1} END {exit !f}' "$report/new-collection.txt" \
  || die "the new collection does not hold XeGfxAccel $version"

next_collection=$(mktemp /Library/KernelCollections/.xegfxaccel.XXXXXX)
install -o root -g wheel -m 744 "$work/AuxiliaryKernelExtensions.kc" "$next_collection"
mv -f "$next_collection" "$collection"
next_collection=""
replaced=1
kcditto > "$report/kcditto.log" 2>&1 || die "could not sync the auxiliary collection to Preboot"
swapped=0 replaced=0
sync
echo "XeGfxAccel $version installed. Reboot through OpenCore."
echo "Undo: sudo bash $0 --restore $backup"
