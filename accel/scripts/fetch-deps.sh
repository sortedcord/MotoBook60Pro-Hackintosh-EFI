#!/bin/bash
# fetch-deps.sh [DIR] -- (re)download everything the acceleration work builds on into DIR
# (default: ../downloads next to this scripts/ folder). Release zips are sha256-checked; git repos are snapshotted.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
D=${1:-$HERE/../downloads}; mkdir -p "$D"; cd "$D"
sha() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1 || sha256sum "$1" | cut -d' ' -f1; }
get() {   # url file sha256 (empty = not pinned)
  [ -f "$2" ] || curl -fL --retry 3 -o "$2" "$1"
  if [ -n "$3" ] && [ "$(sha "$2")" != "$3" ]; then echo "hash mismatch: $2" >&2; exit 1; fi
  echo "ok  $2"
}
get https://github.com/watchthelight-labs/WTLIntelGfx/releases/download/v0.0.48/XeGfx-0.0.48.zip XeGfx-0.0.48.zip \
    55735d7ea6347ea371892dcdb338182d9d4dae32a5f0d0c0a072d02a39294d95
R=https://github.com/samwu07/xegfx-thinkbook14plus-mtl/releases/download/backup-20261104
get $R/xegfx-drivers-20261104-0140.zip xegfx-drivers-20261104-0140.zip \
    9328416634741ada7fd8256235b366e83c090c9ab5201fa782fdfcc60b2b7a1c
get $R/SHA256-public-20261104-0140.txt SHA256-public-20261104-0140.txt ""
grep -i drivers SHA256-public-20261104-0140.txt || true
snap() {   # repo-url name
  [ -f "$2.tar.gz" ] && { echo "ok  $2.tar.gz (exists)"; return; }
  rm -rf "$2.tmp"; git clone -q --depth 1 "$1" "$2.tmp"
  (cd "$2.tmp" && git log -1 --format="$2 %H %cd" ) > "$2.commit.txt"
  tar -czf "$2.tar.gz" -C "$2.tmp" . && rm -rf "$2.tmp"; echo "ok  $2.tar.gz ($(cat "$2.commit.txt"))"
}
snap https://github.com/samwu07/xegfx-thinkbook14plus-mtl xegfx-thinkbook14plus-mtl
snap https://github.com/watchthelight-labs/WTLIntelGfx WTLIntelGfx
snap https://github.com/change-48/XEGFX-MIGRATE XEGFX-MIGRATE
