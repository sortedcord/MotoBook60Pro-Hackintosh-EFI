#!/bin/bash
# build-hid.sh SRC_DIR OUT_DIR -- VoodooI2CHID.kext with the Command Line Tools only (no Xcode), using the
# Xcode project's settings: MacKernelSDK headers/libs, gnu++11, MODULE_NAME com.alexandred.VoodooI2CHID 1.0.0d1.
set -euo pipefail
SRC=$1; OUT=$2; ROOT=$(cd "$SRC/../.." && pwd); SDK=$ROOT/MacKernelSDK
rm -rf "$OUT"; mkdir -p "$OUT/obj" "$OUT/VoodooI2CHID.kext/Contents/MacOS"
CXXF=(-arch x86_64 -mmacosx-version-min=10.11 -fapple-kext -mkernel -nostdinc -nostdinc++ -I"$SDK/Headers"
  -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT -std=gnu++11 -fno-rtti -fno-exceptions -fno-builtin
  -fno-common -O2 -Wno-deprecated-declarations -Wno-inconsistent-missing-override)
cat > "$OUT/obj/info.c" <<'C'
#include <mach/mach_types.h>
extern kern_return_t _start(kmod_info_t *ki, void *data);
extern kern_return_t _stop(kmod_info_t *ki, void *data);
__attribute__((visibility("default"))) KMOD_EXPLICIT_DECL(com.alexandred.VoodooI2CHID, "1.0.0d1", _start, _stop)
__private_extern__ kmod_start_func_t *_realmain = 0;
__private_extern__ kmod_stop_func_t *_antimain = 0;
__private_extern__ int _kext_apple_cc = __APPLE_CC__;
C
xcrun clang -arch x86_64 -mmacosx-version-min=10.11 -mkernel -nostdinc -I"$SDK/Headers" -DKERNEL -DKERNEL_PRIVATE -c "$OUT/obj/info.c" -o "$OUT/obj/info.o"
objs=("$OUT/obj/info.o")
while IFS= read -r f; do
  o="$OUT/obj/$(basename "${f%.cpp}").o"
  xcrun clang++ "${CXXF[@]}" -I"$SRC/VoodooI2CHID" -c "$f" -o "$o" 2>>"$OUT/compile.err" || { grep -A3 ' error:' "$OUT/compile.err" | head -30; exit 1; }
  objs+=("$o")
done < <(find "$SRC/VoodooI2CHID" -name '*.cpp' | sort)
xcrun clang++ -arch x86_64 -mmacosx-version-min=10.11 -fapple-kext -nostdlib -Xlinker -kext -L"$SDK/Library/x86_64" \
  -lkmodc++ -lkmod -lcc_kext "${objs[@]}" -o "$OUT/VoodooI2CHID.kext/Contents/MacOS/VoodooI2CHID"
echo "warnings: $(grep -c ' warning:' "$OUT/compile.err" || true)"
