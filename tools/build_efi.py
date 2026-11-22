#!/usr/bin/env python3
"""Rebuild EFI/ of this repository from its inputs: the Moto Book 60 (Core 7 240H) EFI it is ported from,
OpenCore 1.0.8 and UEFIGraphicsFB 1.0.0. Every change from the 240H EFI is made here, in one place.

    python3 tools/build_efi.py --base EFI-OC.zip --opencore OpenCore-1.0.8-DEBUG.zip \
        --uefigraphicsfb UEFIGraphicsFB-1.0.0-RELEASE.zip [--out EFI]

EFI-OC.zip:       https://github.com/Oppraty/MotoBook60-Hackintosh-EFI (sha256 3723855...)
OpenCore:         https://github.com/acidanthera/OpenCorePkg/releases/tag/1.0.8
UEFIGraphicsFB:   https://github.com/acidanthera/UEFIGraphicsFB/releases/tag/1.0.0
Needs iasl (acpica) to compile acpi-src/.
"""
import argparse, hashlib, os, plistlib, shutil, subprocess, sys, tempfile, zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
G = '7C436110-AB2A-4BBB-A880-FE41995C9F82'
BASE_SHA = '37238556e2808a69fb8ef9dd9f8ac9e5ee8969ee796e49c714cbf20e627c2455'
OC_SHA = '3f5f42b85703cf2c08e8dcd9245a52fb4326c9f4ef335c75b49f516cbbe131c6'

BOOT_ARGS = 'keepsyms=1 -v debug=0x100 -vi2c-force-polling -btlfxboardid -btlfxallowanyaddr -btlfxrealtek'
# Arrow Lake I2C controllers 0/1 (8086:7778, 7779); the mask also covers 777A/777B
ARL_I2C_ID = '0x77788086&0xFFFCFFFF'


def sha(p): return hashlib.sha256(open(p, 'rb').read()).hexdigest()
def die(m): print('ABORT: ' + m); sys.exit(1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--base', required=True); ap.add_argument('--opencore', required=True)
    ap.add_argument('--uefigraphicsfb', required=True); ap.add_argument('--out', default=os.path.join(ROOT, 'EFI'))
    a = ap.parse_args()
    if sha(a.base) != BASE_SHA: die('EFI-OC.zip is not the published 240H EFI')
    if sha(a.opencore) != OC_SHA: die('not OpenCore-1.0.8-DEBUG.zip')
    tmp = tempfile.mkdtemp()
    for z, d in ((a.base, 'base'), (a.opencore, 'oc'), (a.uefigraphicsfb, 'ugfb')):
        zipfile.ZipFile(z).extractall(os.path.join(tmp, d))
    base, oc = os.path.join(tmp, 'base', 'EFI'), os.path.join(tmp, 'oc', 'X64', 'EFI')

    if os.path.exists(a.out): shutil.rmtree(a.out)
    shutil.copytree(base, a.out)
    O = os.path.join(a.out, 'OC')
    for root, dirs, files in os.walk(a.out):          # AppleDouble files break FAT32 ESPs
        for f in files:
            if f.startswith('._') or f == '.DS_Store': os.remove(os.path.join(root, f))
    for root, dirs, files in os.walk(a.out, topdown=False):   # fsck.fat leftovers in the 240H zip: duplicate
        for d in dirs:                                        # copies of VoodooI2CServices / VoodooPS2Keyboard
            if d.upper().startswith('FSCK'): shutil.rmtree(os.path.join(root, d))

    # --- OpenCore 1.0.8 (DEBUG build: logs to the ESP during bring-up) -----------------------------------------
    shutil.copyfile(os.path.join(oc, 'OC', 'OpenCore.efi'), os.path.join(O, 'OpenCore.efi'))
    os.makedirs(os.path.join(a.out, 'BOOT'), exist_ok=True)          # the 240H zip ships EFI/OC only
    shutil.copyfile(os.path.join(oc, 'BOOT', 'BOOTx64.efi'), os.path.join(a.out, 'BOOT', 'BOOTx64.efi'))
    for d in ('OpenCanopy.efi', 'OpenRuntime.efi', 'ResetNvramEntry.efi', 'OpenLinuxBoot.efi', 'Ext4Dxe.efi'):
        shutil.copyfile(os.path.join(oc, 'OC', 'Drivers', d), os.path.join(O, 'Drivers', d))

    # --- kexts -------------------------------------------------------------------------------------------------
    K = os.path.join(O, 'Kexts')
    gone = ['WhateverXe.kext', 'NootedGreen.kext', 'CPUFriend.kext', 'CPUFriendDataProvider.kext',
            'XHCI-unsupported.kext']
    for k in gone: shutil.rmtree(os.path.join(K, k))
    shutil.copytree(os.path.join(tmp, 'ugfb', 'UEFIGraphicsFB.kext'), os.path.join(K, 'UEFIGraphicsFB.kext'))
    vp = os.path.join(K, 'VoodooI2C.kext', 'Contents', 'Info.plist')
    v = plistlib.load(open(vp, 'rb'))
    lake = v['IOKitPersonalities']['VoodooI2CPCILakeController']
    if ARL_I2C_ID not in lake['IOPCIMatch']:
        lake['IOPCIMatch'] += ' ' + ARL_I2C_ID
    plistlib.dump(v, open(vp, 'wb'))

    # --- ACPI ----------------------------------------------------------------------------------------------------
    A = os.path.join(O, 'ACPI')
    os.remove(os.path.join(A, 'SSDT-Disable_Network_RP05.aml'))
    for src in ('SSDT-PLUG-ALT', 'SSDT-PS2VIS'):
        r = subprocess.run(['iasl', '-p', os.path.join(A, src), os.path.join(ROOT, 'acpi-src', src + '.dsl')],
                           capture_output=True, text=True)
        if r.returncode or not os.path.exists(os.path.join(A, src + '.aml')): die(src + ': ' + r.stdout + r.stderr)

    # --- config.plist ---------------------------------------------------------------------------------------------
    cp = os.path.join(O, 'config.plist')
    c = plistlib.load(open(cp, 'rb'))

    acpi = c['ACPI']
    acpi['Add'] = [
        dict(Enabled=False, Path='DSDT-ARLH.aml', Comment='Patched DSDT made by tools/make_acpi_tables.py (not shipped: Lenovo code)'),
        dict(Enabled=False, Path='APIC-ARLH.aml', Comment='Type 0 MADT made by tools/make_acpi_tables.py (not shipped: Lenovo code)'),
        dict(Enabled=True, Path='SSDT-PLUG-ALT.aml', Comment='Processor C000..C02F, IDs 0..47, plugin-type on C000'),
        dict(Enabled=True, Path='SSDT-EC.aml', Comment='Fake EC for Darwin'),
        dict(Enabled=True, Path='SSDT-PS2VIS.aml', Comment='PS2K _STA = 0x0F on Darwin (needs DSDT change C10)'),
        dict(Enabled=True, Path='SSDT-MCHC.aml', Comment='SSDT-MCHC.aml'),
        dict(Enabled=True, Path='SSDT-RTCAWAC.aml', Comment='SSDT-RTCAWAC.aml'),
        dict(Enabled=True, Path='SSDT-USBX.aml', Comment='SSDT-USBX.aml'),
        dict(Enabled=True, Path='SSDT-XOSI.aml', Comment='_OSI answers like Windows under Darwin (needs _OSI->XOSI patch)'),
        dict(Enabled=True, Path='SSDT-PNLF.aml', Comment='Backlight device (no iGPU driver yet, so no brightness control)'),
    ]
    acpi['Delete'] = [
        dict(All=False, Enabled=False, OemTableId=b'CB-01   ', TableLength=856, TableSignature=b'APIC',
             Comment='Drop the native x2APIC-only MADT; make_acpi_tables.py --efi sets ID/length and enables it'),
        dict(All=True, Enabled=True, OemTableId=b'', TableLength=0, TableSignature=b'DMAR',
             Comment='Drop VT-d DMAR: Core Ultra hangs at kernel handoff with it (ThinkBook 14+ MTL finding)'),
    ]

    b = c['Booter']
    b['MmioWhitelist'] = []
    b['Quirks'].update(DevirtualiseMmio=False, ProtectUefiServices=False, AllowRelocationBlock=True)

    c['DeviceProperties']['Add'].pop('PciRoot(0x0)/Pci(0x2,0x0)')   # 240H's EDID override and framebuffer patch

    k = c['Kernel']
    k['Add'] = [e for e in k['Add'] if e['BundlePath'] not in gone]
    for e in k['Add']:
        if e['BundlePath'] == 'CpuTopologyRebuild.kext':
            e['Enabled'] = False
            e['Comment'] = 'Off: Core Ultra 200H has no Hyper-Threading; enable to experiment'
    idx = next(i for i, e in enumerate(k['Add']) if e['BundlePath'] == 'Lilu.kext') + 1
    k['Add'].insert(idx, dict(Arch='x86_64', BundlePath='UEFIGraphicsFB.kext', Comment='Firmware framebuffer for the unsupported Arc 130T',
                              Enabled=True, ExecutablePath='Contents/MacOS/UEFIGraphicsFB', MaxKernel='', MinKernel='',
                              PlistPath='Contents/Info.plist'))
    k['Quirks'].update(AppleXcpmExtraMsrs=True, DisableRtcChecksum=True)

    c['Misc']['Entries'] = []      # the 240H author's Fedora entry (their NVMe's device path)

    nv = c['NVRAM']['Add'][G]
    nv['boot-args'] = BOOT_ARGS

    if not any(d['Path'] == 'Ext4Dxe.efi' for d in c['UEFI']['Drivers']):
        c['UEFI']['Drivers'].append(dict(Arguments='', Comment='ext4, so OpenLinuxBoot finds Linux on the internal SSD',
                                         Enabled=True, HideVerbose=False, LoadEarly=False, Path='Ext4Dxe.efi'))

    g = c['PlatformInfo']['Generic']
    g.update(SystemSerialNumber='C02REPLACE000', MLB='C02REPLACE000000',
             SystemUUID='00000000-0000-0000-0000-000000000000', ROM=bytes(6))
    c['#Comment-Port'] = ('Moto Book 60 Pro, Core Ultra 5 225H (Arrow Lake-H). Ported from Oppraty/MotoBook60-Hackintosh-EFI '
                          '(Core 7 240H) by tools/build_efi.py')
    plistlib.dump(c, open(cp, 'wb'), sort_keys=True)

    ocv = os.path.join(tmp, 'oc', 'Utilities', 'ocvalidate', 'ocvalidate.linux')
    os.chmod(ocv, 0o755)
    r = subprocess.run([ocv, cp], capture_output=True, text=True)
    print(r.stdout.strip().splitlines()[-1])
    if 'No issues found' not in r.stdout: die('ocvalidate:\n' + r.stdout)
    shutil.rmtree(tmp)
    print('EFI written to ' + a.out)


if __name__ == '__main__':
    main()
