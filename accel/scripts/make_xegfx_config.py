#!/usr/bin/env python3
"""make_xegfx_config.py ESP -- write XEGFX-HANDOFF/efi/config-safe.plist (= the live config.plist) and
config-xegfx.plist (+ XeGfx.kext via Kernel/Add right after Lilu, + boot-arg xegfx.nvram_trace=0), and copy
XeGfx.kext into EFI/OC/Kexts from downloads/XeGfx-0.0.48.zip (sha256-checked). The live config.plist is not touched;
switch with efi-switch.sh. Rerun after any change to the safe config so both stay in step.

XeGfx's only IOKit personality waits for IOResource XeGfxArm, which the kext publishes itself after
`kmutil load -b org.watchthelight.XeGfx`, so the injected kext stays idle at boot (the ThinkBook 14+ route, CLEAN-07Y).
"""
import hashlib, io, os, plistlib, shutil, sys, zipfile

XEGFX_ZIP_SHA = '55735d7ea6347ea371892dcdb338182d9d4dae32a5f0d0c0a072d02a39294d95'
G = '7C436110-AB2A-4BBB-A880-FE41995C9F82'
EXTRA_ARGS = ['xegfx.nvram_trace=0', 'amfi=0x80']   # amfi: WindowServer loads the ad hoc Metal plugin (autostart)


def main():
    if len(sys.argv) != 2: sys.exit(__doc__)
    esp = sys.argv[1]
    cfgp = os.path.join(esp, 'EFI/OC/config.plist')
    h = os.path.join(esp, 'XEGFX-HANDOFF')
    z = os.path.join(h, 'downloads/XeGfx-0.0.48.zip')
    data = open(z, 'rb').read()
    if hashlib.sha256(data).hexdigest() != XEGFX_ZIP_SHA: sys.exit('XeGfx-0.0.48.zip hash mismatch')
    raw = open(cfgp, 'rb').read()
    c = plistlib.loads(raw)
    if any(k['BundlePath'] == 'XeGfx.kext' for k in c['Kernel']['Add']):
        sys.exit('the live config.plist already injects XeGfx: switch to safe first (efi-switch.sh safe)')
    os.makedirs(os.path.join(h, 'efi'), exist_ok=True)
    open(os.path.join(h, 'efi/config-safe.plist'), 'wb').write(raw)

    kd = os.path.join(esp, 'EFI/OC/Kexts/XeGfx.kext')
    if os.path.exists(kd): shutil.rmtree(kd)
    zipfile.ZipFile(io.BytesIO(data)).extractall(os.path.join(esp, 'EFI/OC/Kexts'))
    for root, dirs, files in os.walk(kd):           # no AppleDouble files on the FAT32 ESP
        for f in files:
            if f.startswith('._'): os.remove(os.path.join(root, f))

    i = next(n for n, k in enumerate(c['Kernel']['Add']) if k['BundlePath'] == 'Lilu.kext') + 1
    c['Kernel']['Add'].insert(i, dict(
        Arch='x86_64', BundlePath='XeGfx.kext', Enabled=True, ExecutablePath='Contents/MacOS/XeGfx',
        MinKernel='24.0.0', MaxKernel='', PlistPath='Contents/Info.plist',
        Comment='WTLIntelGfx XeGfx 0.0.48 (official zip), idle until kmutil load -b org.watchthelight.XeGfx'))
    ba = c['NVRAM']['Add'][G]['boot-args'].split()
    for x in EXTRA_ARGS:
        if x not in ba: ba.append(x)
    c['NVRAM']['Add'][G]['boot-args'] = ' '.join(ba)
    c['#Comment-XeGfx'] = 'config-xegfx: config-safe + XeGfx 0.0.48 Kernel/Add + ' + ' '.join(EXTRA_ARGS)
    plistlib.dump(c, open(os.path.join(h, 'efi/config-xegfx.plist'), 'wb'), sort_keys=True)
    print('wrote efi/config-safe.plist and efi/config-xegfx.plist; XeGfx.kext in EFI/OC/Kexts')
    print('boot-args (xegfx):', c['NVRAM']['Add'][G]['boot-args'])


if __name__ == '__main__':
    main()
