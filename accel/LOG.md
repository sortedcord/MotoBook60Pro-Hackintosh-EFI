# Acceleration bring-up log

Newest entry last. One entry per step: date, side (Linux/macOS), what ran, the result, the next step.

## 2026-11-22 (Linux side)
- macOS Sequoia installed on the USB SSD; the user reports desktop, Wi-Fi and Bluetooth working (UEFIGraphicsFB,
  no acceleration).
- Collected i915 data on Linux 7.3 (`hardware/`): GuC 70.53.0 / DMC 2.23 / HuC 8.5.4 (mtl_*), graphics 12.74,
  platform METEORLAKE, eDP 1920x1200@60 on pipe A, 2 lanes, PWM backlight (max 400).
- Prepared the ESP: `XEGFX-HANDOFF/` (this folder + downloads, sha256-checked), `efi/config-safe.plist` (= live
  config) and `efi/config-xegfx.plist` (+ XeGfx 0.0.48 Kernel/Add, `xegfx.nvram_trace=0`), XeGfx.kext copied to
  EFI/OC/Kexts. Both configs pass ocvalidate 1.0.8. **Live config = safe** (nothing changed for the next boot).
- Next: Gate 0 on macOS (`scripts/collect-baseline.sh`), then `efi-switch.sh xegfx` + reboot (Gate 1).
