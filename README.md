# Moto Book 60 Pro (Core Ultra 5 225H) — OpenCore EFI

An OpenCore 1.0.8 EFI for macOS Sequoia 15 on the **Motorola moto book 60 pro, 14IAH10 / 83NY, Intel Core Ultra 5
225H (Arrow Lake-H)**.

It is a port of **[Oppraty/MotoBook60-Hackintosh-EFI](https://github.com/Oppraty/MotoBook60-Hackintosh-EFI)**, the
daily-driver EFI for the Moto Book 60 with the **Core 7 240H** (Raptor Lake). That repository did the work on Realtek
Wi-Fi and Bluetooth, the Ethernet trick, input, battery and the EFI layout this one keeps. Read its
[GUIDE.md](https://github.com/Oppraty/MotoBook60-Hackintosh-EFI/blob/main/GUIDE.md) as well. The 240H and 225H
models share the chassis, the Realtek RTL8922A Wi-Fi/BT and most peripherals, but not the chipset. This repository
is about that difference.

> **Status: untested bring-up EFI.** The config passes `ocvalidate`, and the ACPI tables compile and were generated
> from a real 225H. It has not booted macOS yet. Keep another boot entry, and expect to iterate with `-v`.

## Why the 240H EFI does not work on a 225H

| | Core 7 240H (original) | Core Ultra 5 225H (this repo) |
|---|---|---|
| Platform | Raptor Lake-P + PCH | Arrow Lake-H SoC (Meteor Lake family) |
| iGPU | Iris Xe `8086:A7AB` (Xe-LP) → WhateverXe | Arc 130T `8086:7D51` (Xe-LPG+) → **no macOS driver** |
| Panel | 2880×1800 OLED | 1920×1200 OLED (ATNA40CT03) |
| CPU | 6P+4E, Hyper-Threading, 16 threads | 4P+8E+2LP-E, **no HT**, 14 threads |
| MADT | type 0 Local APIC | **x2APIC only (type 9)**, which macOS can't use |
| DSDT | works with renames | PCH devices behind module-level `PCHS` guards, dynamic `_CRS`, xHCI `_PSx` PCI reads |
| I2C | PCH LP controller | `8086:7778/7779` (not in VoodooI2C), GPIO `INTC105E` (no VoodooGPIO table) |
| xHCI | PCH `A0ED`-style | `8086:777D` (+ TCSS `7EC0`) |

## What was changed (all in [`tools/build_efi.py`](tools/build_efi.py))

- **Graphics:** removed WhateverXe, NootedGreen, the 240H EDID override and the framebuffer patch. Added
  **UEFIGraphicsFB**, so macOS uses the firmware's GOP framebuffer: 1920×1200 at 60 Hz, **no acceleration, no
  Metal, no brightness control, no sleep-safe display**. The only acceleration work for `7D51` is the experimental
  [WTLIntelGfx/XeGfx](https://github.com/watchthelight-labs/WTLIntelGfx) (see
  [#14](https://github.com/watchthelight-labs/WTLIntelGfx/issues/14)). It is not included here.
- **ACPI:** new [`tools/make_acpi_tables.py`](tools/make_acpi_tables.py) builds a patched **DSDT** and a
  **type 0 MADT** from your own firmware. They are not shipped because they are Lenovo code. It is a Linux/Python
  port of `make-acpi-tables.ps1` from [samwu07/xegfx-thinkbook14plus-mtl](https://github.com/samwu07/xegfx-thinkbook14plus-mtl)
  (ThinkBook 14+ Meteor Lake, same Lenovo `CB-01` firmware family). On this machine it applies C1–C3 and C5–C10.
  `SSDT-PLUG-ALT` was regenerated with 48 `Processor` objects to match. New `SSDT-PS2VIS` keeps the PS/2 keyboard
  visible. Dropped `SSDT-Disable_Network_RP05` (Wi-Fi is on RP08 here, and it was disabled anyway). **DMAR** is
  dropped.
- **CPU:** CPUFriend and its 240H DataProvider removed (the frequency table was for another CPU).
  CpuTopologyRebuild disabled (no HT). `AppleXcpmExtraMsrs` on. Cpuid1 spoof kept (Comet Lake `0x0A0655`).
- **Touchpad (Goodix GXTP5100 on I2C0):** VoodooI2C's Lake controller gets `0x77788086&0xFFFCFFFF`, and the boot
  arg `-vi2c-force-polling` is added because VoodooGPIO has no Arrow Lake pin table.
- **USB:** removed XHCI-unsupported (no Arrow Lake IDs; USBToolBox + UTBDefault match by PCI class). The DSDT patch
  sets the port counts: 10 USB2 + 2 USB3, measured with Linux.
- **Booter:** the 240H's MMIO whitelist removed. `DevirtualiseMmio` and `ProtectUefiServices` off,
  `AllowRelocationBlock` on (what booted on Meteor Lake).
- **OpenCore 1.0.8 DEBUG**, all drivers refreshed. Added `Ext4Dxe` so OpenLinuxBoot finds Linux. Removed the 240H
  author's Fedora boot entry. Boot args are now `-v debug=0x100` for bring-up.
- **Kept unchanged:** Realtek RTL8922A Wi-Fi/BT stack (same `10EC:8922` and `0BDA:D922` IDs on the 225H),
  AppleALC (the codec here is Conexant SN6140 `14F1:1F87`, and layout 15 is the community layout for it), VirtualSMC
  + SMCBatteryManager + ReYogaSMC (Lenovo EC `VPC2004`), VoodooPS2, BrightnessKeys, `SSDT-EC` (`H_EC` doesn't exist
  here, so its rename is a no-op and only the fake EC is added), `SSDT-XOSI` and `SSDT-RTCAWAC`.

## Hardware (read from a real 83NY under Linux)

| Device | ID | macOS driver |
|---|---|---|
| iGPU | `8086:7D51` rev 3 | UEFIGraphicsFB (framebuffer only) |
| Wi-Fi | `10EC:8922` (RP08, `00:1C.7`) | AirPort_RTW89 + IO80211FamilyLegacy + IOSkywalkFamily |
| Bluetooth | USB `0BDA:D922` | BlueToolFixup (Realtek) + BTNameFix |
| Audio | Conexant SN6140 `14F1:1F87`, sub `17AA:3841` | AppleALC layout 15 (unverified) |
| Touchpad | Goodix `GXTP5100` (`27C6:01E0`) on I2C0 | VoodooI2C + VoodooI2CHID, polling |
| Keyboard | PS/2 `PS2K` | VoodooPS2 |
| NVMe | SK hynix PVC10 `1C5C:1F69` | native |
| SD reader | O2 Micro `1217:8621` | none |
| Camera | USB `04F2:B829` | probably native UVC |
| NPU, ISH, IPU | — | none |

## Install

1. **USB stick.** GPT, with a FAT32 EFI partition of at least 1 GB and a second partition of at least 64 GB for
   macOS, or use another disk.
2. **Recovery.** In the ESP root: `python3 macrecovery.py -b Mac-7BA5B2D9E42DDD94 -m 00000000000000000 download`
   (from OpenCorePkg `Utilities/macrecovery`) into `com.apple.recovery.boot/`.
3. **EFI.** Copy this repo's `EFI/` to the ESP.
4. **ACPI tables.** Boot Linux on the laptop *from the firmware boot menu (F12), not through OpenCore*, then run:
   ```
   sudo pacman -S acpica        # or: apt install acpica-tools
   sudo python3 tools/make_acpi_tables.py --efi /mnt/esp/EFI
   ```
   This writes `DSDT-ARLH.aml` and `APIC-ARLH.aml` into `EFI/OC/ACPI`, enables them, and points `ACPI > Delete`
   at your native MADT. Check `acpi-out/report.txt`. Every change except C4 should say `applied`.
5. **SMBIOS.** Run `macserial -m MacBookPro16,2 -g -n 1`. Use the output as `SystemSerialNumber | MLB`, a fresh
   UUID as `SystemUUID`, and your Wi-Fi MAC as `ROM`.
6. **Firmware (F2).** Secure Boot off. If they are offered: VT-d off, VMD off, Intel PTT optional.
7. **Boot** the stick with F12, choose *macOS Base System*, erase the second partition as APFS in Disk Utility,
   and install.

## Known limits and what to expect

- No graphics acceleration. The UI is CPU-drawn and slow, there are no transparency effects, and video is
  software-decoded. Brightness keys will not work. Sleep is untested and probably wakes to a black screen.
- E-cores and LP E-cores are scheduled as ordinary cores. Without CPUFriend there is no tuned frequency table.
- The touchpad uses polling (higher idle CPU use). See the ThinkBook repo for a VoodooI2CHID glitch-guard patch.
- If it hangs early, boot with the DEBUG log (`Misc > Debug > Target = 67` is already set) and read the
  `opencore-*.txt` on the ESP.
- AppleALC layout 15 for SN6140 comes from a community report on another laptop. If there's no sound, try other
  layouts or remove `layout-id`.

## Rebuilding EFI/

```
python3 tools/build_efi.py --base EFI-OC.zip --opencore OpenCore-1.0.8-DEBUG.zip \
    --uefigraphicsfb UEFIGraphicsFB-1.0.0-RELEASE.zip
```
The script checks the hashes of the 240H zip and the OpenCore zip, then runs `ocvalidate` at the end.

## Credits

- **[Oppraty/MotoBook60-Hackintosh-EFI](https://github.com/Oppraty/MotoBook60-Hackintosh-EFI)**: the 240H EFI
  this is built from, and the Realtek Wi-Fi/BT/Ethernet work.
- **[samwu07/xegfx-thinkbook14plus-mtl](https://github.com/samwu07/xegfx-thinkbook14plus-mtl)** (BSD-2): the DSDT
  and MADT patch logic that `make_acpi_tables.py` ports, the DMAR finding and the Booter quirks.
- **[VedCloud](https://github.com/VedCloud/Meteor-Lake-Xe-LPG-Metal-Graphics)**: the MADT and SSDT-PLUG-ALT
  layout for Core Ultra.
- acidanthera (OpenCore, Lilu, VirtualSMC, AppleALC, VoodooPS2, UEFIGraphicsFB), VoodooI2C, USBToolBox, and the
  authors of every kext listed in the original repo.

Licences: OpenCore BSD-3. Each kext is under its own licence. `tools/make_acpi_tables.py` is BSD-2-Clause like the
script it ports. No Lenovo ACPI tables are in this repository.
