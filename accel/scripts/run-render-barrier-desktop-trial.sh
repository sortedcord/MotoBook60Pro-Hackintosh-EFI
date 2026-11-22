#!/bin/bash
# Use the approved AMFI test boot to try the offscreen-verified renderer in WindowServer.
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin

die() { echo "render-barrier-desktop-trial: $*" >&2; exit 1; }
[ "${1:-}" = --restart-windowserver ] || die "save your work, then run with --restart-windowserver"
[ "$(id -u)" = 0 ] || die "run with sudo"
scripts=$(cd "$(dirname "$0")" && pwd)
handoff=$(cd "$scripts/.." && pwd)
esp=$(cd "$handoff/.." && pwd)
gpu=/Library/GPUBundles
plugin="$gpu/NVMTLDriver.bundle"
allowlist="$gpu/nvmtl-allow.txt"
candidate="$handoff/candidates/render-barrier-a9dfe278"

case " $(sysctl -n kern.bootargs) " in
  *' amfi=0x80 '*) ;;
  *) die "boot the approved AMFI test configuration first" ;;
esac
if cmp -s "$esp/EFI/OC/config.plist" "$handoff/efi/config-xegfx-amfi-test.plist"; then
  bash "$scripts/efi-switch.sh" xegfx "$esp"
fi
cmp -s "$esp/EFI/OC/config.plist" "$handoff/efi/config-xegfx.plist" || die "could not restore the standard config on disk"
[ "$(cat "$allowlist")" = '-WindowServer' ] || die "expected the desktop plugin to be disabled before the test"
[ "$(sysctl -n debug.xegfx_agdc)" = 0 ] || die "start the trial with graphics device control idle"
(cd "$candidate" && shasum -a 256 -c SHA256SUMS)
codesign --verify --deep --strict "$plugin"
codesign --verify --deep --strict /Library/XeGfx/metal/NVMTLDriver.bundle

report=$(mktemp -d "$handoff/reports/render-barrier-desktop-$(date +%Y%m%d-%H%M%S)-XXXXXX")
echo "Reports: $report"
staging=$(mktemp -d /Library/XeGfx/.render-barrier-trial.XXXXXX)
backup=$(mktemp -d /Library/XeGfx/backup-render-barrier-XXXXXX)
replacement=""
installed=0
cleanup() {
  local rc=$?
  trap - EXIT
  if [ "$rc" -ne 0 ] && [ -d "$backup/NVMTLDriver.bundle" ]; then
    replacement=$(mktemp "$gpu/.nvmtl-allow.XXXXXX")
    printf '%s\n' '-WindowServer' > "$replacement"
    chmod 644 "$replacement"
    mv -f "$replacement" "$allowlist"
    if [ "$installed" = 1 ]; then mv "$plugin" "$staging/failed.bundle"; fi
    mv "$backup/NVMTLDriver.bundle" "$plugin"
  fi
  rm -rf "$staging"
  sync
  exit "$rc"
}
trap cleanup EXIT

ditto --norsrc --noextattr /Library/XeGfx/metal/NVMTLDriver.bundle "$staging/NVMTLDriver.bundle"
install -o root -g wheel -m 755 "$candidate/NVMTLDriver" "$staging/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver"
codesign --force --sign - "$staging/NVMTLDriver.bundle"
codesign --verify --deep --strict "$staging/NVMTLDriver.bundle"
bash "$scripts/run-xegfx-stages.sh" 7 | tee "$report/stage-runner.txt"
[ "$(sysctl -n debug.nvaccel_xeflip)" = 0 ] || die "zero-copy must stay off for this trial"

printf '%s\n' "$backup/NVMTLDriver.bundle" > "$report/previous-plugin.txt"
mv "$plugin" "$backup/NVMTLDriver.bundle"
mv "$staging/NVMTLDriver.bundle" "$plugin"
installed=1
shasum -a 256 "$plugin/Contents/MacOS/NVMTLDriver" > "$report/active-plugin.txt"
replacement=$(mktemp "$gpu/.nvmtl-allow.XXXXXX")
printf '%s\n' '!WindowServer' > "$replacement"
chmod 644 "$replacement"
mv -f "$replacement" "$allowlist"
sync
bash "$scripts/desktop-on.sh" --restart-windowserver --framebuffer-fetch | tee "$report/activation-location.txt"
