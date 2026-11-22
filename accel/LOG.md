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

## 2026-11-22 (macOS side, Gate 0)

- Ran `sudo bash scripts/collect-baseline.sh` from the OpenCore ESP. The report is at
  `/Volumes/OPENCORE/XEGFX-HANDOFF/reports/baseline-20261122-104456/`.
- macOS Sequoia **15.8.3 (24H241)**, Darwin **24.6.0**, running on the Core Ultra 5 225H and Arc 130T
  `8086:7D51` rev 3. UEFIGraphicsFB 1.0.0 and AMFIPass 1.4.1 are loaded. IORegistry shows the boot framebuffer
  and PNLF. SIP is `0x0803` with authenticated root disabled. Command Line Tools are already installed.
- `system_profiler` lists no audio device. Keyboard, touchpad and physical audio checks are pending user confirmation.
- Mounted `OPENCORE` (`disk1s1`) with `sudo diskutil mount disk1s1`. Non-repairing FAT verification passed.
  Verified byte-for-byte that the live config matched the safe copy and that the ESP copy of XeGfx 0.0.48 matched
  the pinned release ZIP. The staged plist adds XeGfx after Lilu and appends `xegfx.nvram_trace=0`.

## 2026-11-22 (macOS side, Gate 1 prepared)

- Ran `bash scripts/efi-switch.sh xegfx /Volumes/OPENCORE` and confirmed that `EFI/OC/config.plist` matches
  `efi/config-xegfx.plist` byte-for-byte. The previous config is in `efi/backups/config-20261122-104623.plist`.
  `efi/config-safe.plist` is also available for rollback.
- Next boot uses the XeGfx configuration. Reboot from the external OpenCore drive and verify that the desktop
  stays responsive for 10–15 minutes. Mount `OPENCORE` again and run `sudo bash scripts/run-xegfx-stages.sh 2`
  from the ESP handoff. Record the stage results and framebuffer placement before continuing to Gate 2.

## 2026-11-22 (macOS side, Gate 1 boot)

- Rebooted at **10:51:18 IST**. The running kernel has `xegfx.nvram_trace=0`, and UEFIGraphicsFB is
  driving the desktop. XeGfx is awaiting its on-demand load. The user remounted `OPENCORE`.
- Updated the stage runner to log the watchdog setup, require a passing result for each new stage, and return
  failure when a stage fails. The framebuffer report uses the driver's page mask and identifies
  GuC slot overlaps for comparison with the stage 4 move result.

## 2026-11-22 (macOS side, Gate 1 passed)

- The user confirmed the desktop was stable and shortened the observation period. Loaded XeGfx 0.0.48 and ran
  stages 1–2 at **10:57 IST**. Both reported `1`. WindowServer stayed at PID 159 across both stages.
- Stage 2 found `8086:7D51` rev 3, graphics GMD ID `0x03128004`, display GMD ID `0x0380000C`, and stolen
  base `0x70800000`. Pipe A was lit and reported frame count 21737. The 1920×1200 boot framebuffer occupies
  `0xFF600000–0xFFECA000` in the GGTT (end exclusive, 9000 KiB). The GuC slot ends at `0xFF000000`.
- Reports: `/Volumes/OPENCORE/XEGFX-HANDOFF/reports/stages-20261122-105703-XqzG8u/`.
- Next: run stages 3–4 and check the panel and framebuffer move result before running stages 5–6.

## 2026-11-22 (macOS side, Gate 2 stages 3–4)

- Stages 3–4 passed at **10:58 IST**. i915 attached to `8086:7D51`, skipped display initialization, and loaded
  GuC 70.53.0 on GT0 with submission enabled. The driver exposed three engines and reported `wedged=0`.
  It skipped GT1 (standalone media) because the FreeBSD port lacks the MEI driver.
- `xegfx-fbmove` returned status `0` (move unnecessary). After initialization the GGTT surface and PTE matched
  the pre-init probe, and the pipe frame counter advanced by 6. The user confirmed that the panel looks normal.
- Reports: `/Volumes/OPENCORE/XEGFX-HANDOFF/reports/stages-20261122-105801-LWO0yc/`.
- Next: run stages 5–6 to test GPU execution and CPU readback on the engines exposed by i915.

## 2026-11-22 (macOS side, Gate 2 passed)

- Stages 5–6 passed at **10:58 IST**. `rcs0`, `bcs0` and `ccs0` each completed GPU work, delivered an
  interrupt, and returned the expected memory value to the CPU. The results array was `0 1 1 1 1 1 1 0`.
- Reports: `/Volumes/OPENCORE/XEGFX-HANDOFF/reports/stages-20261122-105858-hbNA9F/`.
- Next: validate XeGfxAccel 0.9.5 against this Sequoia build and run the private Metal probe after stage 7.

## 2026-11-22 (macOS side, Gate 3 preflight)

- Linked XeGfxAccel 0.9.5 in a temporary auxiliary collection on Sequoia 15.8.3. The candidate retained
  AppleMobileDevice and both HighPoint extensions from the live collection.
- The pinned archive's plugin seal referenced an omitted `NVMTLDriver.prev` file. Ad hoc re-signing of
  the plugin passed strict recursive verification. The bundled ANV libraries and ICD already point to
  `/Library/GPUBundles/nvmtl`, and the upstream `mtlprobe` compiled with the installed Command Line Tools.
- Added `scripts/install-metal-probe.sh` for the private install and `scripts/test-metal-probe.sh` for the
  logged-in user after stage 7. The install keeps the framebuffer and desktop kexts for later steps.

## 2026-11-22 (macOS side, Gate 3 private Metal stack installed)

- Ran `scripts/install-metal-probe.sh` at **11:04 IST**. The live auxiliary collection contains XeGfxAccel 0.9.5,
  AppleMobileDevice, HighPointIOP, and HighPointRR. Installed ANV under `/Library/GPUBundles/nvmtl` and the
  verified plugin under `/Library/XeGfx/metal`. Desktop components are deferred until the private probe passes.
- The original auxiliary collection is backed up at `/Library/XeGfx/backup/AuxiliaryKernelExtensions.kc` and
  in `/Volumes/OPENCORE/XEGFX-HANDOFF/reports/metal-install-20261122-110355-UXYqcc/`. The copies match.
- Next: reboot from the external OpenCore drive, remount `OPENCORE`, run `sudo bash scripts/run-xegfx-stages.sh 7`,
  and confirm `NMXAccel` attaches. Then run `bash scripts/test-metal-probe.sh` as the logged-in user to verify
  Metal compute and draw. This probe runs before any WindowServer changes.

## 2026-11-22 (macOS side, Gate 3 passed)

- Booted at **11:06:51 IST**, mounted `OPENCORE`, and ran stages 1–7. All passed. The new auxiliary collection
  attached XeGfxAccel as `NMXAccel` when stage 7 claimed the iGPU. The stage 4 framebuffer result was still `0`.
- The private Metal probe on **Intel(R) Graphics (ARL)** passed compute and draw. All 1024 compute values matched,
  the test geometry produced 512 green pixels, and the background and center matched the expected colors.
- Reports: `/Volumes/OPENCORE/XEGFX-HANDOFF/reports/stages-20261122-110832-an9ABL/` and
  `/Volumes/OPENCORE/XEGFX-HANDOFF/reports/metal-probe-20261122-110848-t5SlGf/`.
- Next: test CoreDisplay's three precompiled pipelines inside the private probe before WindowServer uses the plugin.

## 2026-11-22 (macOS side, CoreDisplay probe passed)

- At **11:10 IST**, the private plugin's built-in LLVM reader built all three CoreDisplay pipelines from this boot's
  `default.metallib` with a fresh translation cache. `GPUPass`, `ColorFill`, and `TextureCopy` all reported
  `PIPELINE BUILT`. The separate Metal compute and draw checks also passed on the Arc 130T.
- Report: `/Volumes/OPENCORE/XEGFX-HANDOFF/reports/metal-probe-20261122-111045-9Rz21e/`. The temporary probe
  flag was removed after the test.
- Next: install XeGfxIntelFB 0.9.4 with `0x7d518086` added to its PCI match. Check its panel attachment after reboot.

## 2026-11-22 (macOS side, Intel framebuffer staged)

- At **11:12 IST**, installed XeGfxIntelFB 0.9.4 with match `0x7d558086 0x7d678086 0x7d518086`. Its new
  signature verified, and the auxiliary collection contains the framebuffer kext and all four previous extensions,
  including XeGfxAccel 0.9.5. The global plugin and XeGfxAGDC are deferred until the panel check passes.
- Previous collection: `/Library/XeGfx/backup-framebuffer-KCzCnA/AuxiliaryKernelExtensions.kc`. The ESP copy
  in `/Volumes/OPENCORE/XEGFX-HANDOFF/reports/framebuffer-install-20261122-111241-a7iegT/` contains all four
  previous extensions and can be read with `kmutil inspect`.
- Next: reboot through the external OpenCore drive. Check that the panel looks normal and `display0` appears
  beneath `XeGfxIntelFramebuffer`. If the panel fails, use Safe Mode or Recovery to remove the added kext
  and restore this step's saved auxiliary collection.

## 2026-11-22 (macOS side, Intel framebuffer verified)

- Rebooted at **11:14:57 IST**. XeGfxIntelFB 0.9.4 loaded, and IORegistry shows `display0` attached to
  `XeGfxIntelFramebuffer` with `NVRMTiming` available. The desktop is reachable.
- Reran XeGfx stages 1–7 at **11:16 IST**. All passed. The framebuffer stayed at `0xFF600000–0xFFECA000`,
  its move result was `0`, and `NMXAccel` attached with the Intel framebuffer still active.
- Report: `/Volumes/OPENCORE/XEGFX-HANDOFF/reports/stages-20261122-111649-3BqYIw/`.
- Next: stage XeGfxAGDC and publish the verified plugin with an armed-only WindowServer allow-list, then reboot.
- Prepared `scripts/install-xegfx-desktop-component.sh` and `scripts/desktop-on.sh`. Tested that the activation
  script restarts the original WindowServer PID after arming and disables the plugin if arming fails. The install
  is waiting for the macOS administrator prompt.

## 2026-11-22 (macOS side, WindowServer components staged)

- At **11:24 IST**, installed XeGfxAGDC 0.1.1 and copied the verified plugin to `/Library/GPUBundles/`.
  The allow-list contains `!WindowServer`, which activates only after the display pipe is armed. Both signatures
  verified, and the new auxiliary collection contains XeGfxAGDC and all five prior extensions. Boot arguments
  and SIP settings are the same as for the private Metal probe.
- Previous collection: `/Library/XeGfx/backup-compositor-lnBOdB/AuxiliaryKernelExtensions.kc`. The ESP backup
  in `/Volumes/OPENCORE/XEGFX-HANDOFF/reports/compositor-install-20261122-112417-BUuIJ3/` was verified with
  `kmutil inspect`.
- Next: reboot through the external OpenCore drive, log in, and save your work. Verify the AGDC loader and Intel
  framebuffer, run XeGfx stages 1–7, then activate with `sudo bash scripts/desktop-on.sh --restart-windowserver`.
  Log in again and check that WindowServer's display-pipe counters advance.

## 2026-11-22 (macOS side, WindowServer activation failed)

- Booted at **11:27:16 IST** with XeGfxIntelFB and XeGfxAGDC loaded. XeGfx stages 1–7 passed again and
  `NMXAccel` attached. AGDC, K5, and display-pipe transactions armed successfully at **11:29 IST**.
- AMFI library validation repeatedly rejected the ad hoc `NVMTLDriver` when Apple platform binary WindowServer
  tried to map it. All eight WindowServer reports show an assertion in `CoreDisplay_CreateDisplayForCGXDisplayDevice`.
  The display-pipe counters stayed at zero. The private Metal and CoreDisplay pipeline results still stand.
- The guard wrote `-WindowServer` at **11:29:56 IST**. macOS continued rejecting the mapping before the plugin
  could read the allow-list. The **11:31:30 IST** reboot restored a stable desktop on XeGfxIntelFramebuffer,
  with the accelerator idle and `-WindowServer` saved. Added an activation preflight for the known rejection.
- Reports: `/Volumes/OPENCORE/XEGFX-HANDOFF/reports/desktop-on-20261122-112923-Xvxm4z/` and
  `/Volumes/OPENCORE/XEGFX-HANDOFF/reports/desktop-crash-20261122-113049/`.
- Next: confirm the security setting for the next desktop test before changing the boot configuration or retrying
  WindowServer activation.

## 2026-11-22 (macOS side, AMFI test boot staged)

- The user authorized one test boot with relaxed AMFI enforcement. At **11:35 IST**, staged
  `efi/config-xegfx-amfi-test.plist` as the live external OpenCore config. Its only semantic change is appending
  `amfi=0x80` to `boot-args`. The plugin allow-list still reads `-WindowServer` and the original XeGfx config
  is saved in `efi/config-xegfx.plist` and `efi/backups/config-pre-amfi-20261122-113552.plist`.
- Next: reboot from external OpenCore and verify `amfi=0x80` in the running kernel. Restore `config-xegfx.plist`
  on disk for subsequent boots. In the approved test boot, explicitly rearm the plugin, run stages 1–7, and
  restart WindowServer after saving work. Check plugin loading and display-pipe counters before further changes.

## 2026-11-22 (macOS side, GPU desktop verified with rendering artifacts)

- Booted at **11:37:15 IST** with `amfi=0x80`. Restored the standard `config-xegfx.plist` on the ESP before
  arming XeGfx. Stage 7 passed. WindowServer restarted once and PID 1356 loaded the plugin and opened Intel ANV.
- The user saw transparency and widespread graphical corruption. The display pipe presented 2,996 frames by
  **11:46:41 IST**, with zero reported failures and zero zero-copy flips. The plugin logged that framebuffer
  fetch was off for WindowServer and shaders reading `[[color(n)]]` got a dummy image.
- Reports: `/Volumes/OPENCORE/XEGFX-HANDOFF/reports/desktop-on-20261122-114243-gvrbLm/` and
  `/Volumes/OPENCORE/XEGFX-HANDOFF/reports/desktop-glitches-20261122-114544/`.
- The user authorized another WindowServer restart in this boot to test `NVMTL_FBFETCH_WS=1` in isolation.

## 2026-11-22 (macOS side, framebuffer fetch and zero-copy crash)

- Restarted WindowServer with `NVMTL_FBFETCH_WS=1` set for one launch. PID 2964 logged framebuffer fetch ON.
  The user reported that the Dock blurred its backdrop correctly and that artifacts and ghosting remained.
- The zero-copy trial recorded 1,033 flips, zero fallback copies, and zero presentation failures. The main
  test restored `debug.nvaccel_xeflip=0` at **11:52:16 IST**. The independent timer failed to detach from
  the console. WindowServer PID 2964 hit its stack guard at **11:52:18.645 IST**. Its stack alternated between
  SkyLight's `RenderEncoder` and `SetScissor` 254 times each, above calls into NVMTL. The timing associates the
  crash with the trial but leaves the original rendering failure unresolved. VedCloud recorded the same recursion
  pattern on another XeGfx system. [VedCloud bring-up report](https://github.com/VedCloud/Meteor-Lake-Xe-LPG-Metal-Graphics/blob/main/ROADMAP.md#18-october--phase-3-first-submissions-first-hang-024--029)
- Replacement WindowServer processes aborted in CoreDisplay. The guard wrote `-WindowServer` at
  **11:52:19 IST**. Rebooted at **11:53:41 IST** through the standard OpenCore config and returned to the
  Intel framebuffer desktop, with AGDC idle and XeGfx's runtime stages inactive.
- The first stack-overflow report, the later assertion, and the frame and kernel logs are saved in
  `/Volumes/OPENCORE/XEGFX-HANDOFF/reports/desktop-glitches-20261122-114544/`.
- The installed plugin lacks the snapshot refresh entry from the ThinkBook render-barrier patch. That fix
  improved ghosting and translucency on a related Sequoia system and is a separate candidate from scanout.
  [ThinkBook render-barrier report](https://github.com/samwu07/xegfx-thinkbook14plus-mtl/issues/2)

## 2026-11-22 (macOS side, private render-barrier candidate built)

- Built the userspace plugin from the saved WTLIntelGfx `a9dfe27820430fe5dc261a86b16a62f762d25740` source with
  Khronos Vulkan-Headers `v1.4.328`. The render-barrier hunk applied cleanly. The complete downstream patch
  has a conflicting row-pitch hunk against this source. The candidate uses the render-barrier change alone.
- Verified the candidate's ad hoc signature and loaded it in a user process. The `NVMTLDevice` class and
  `nvmtlRefreshSnapshotAtTextureBarrier` method were present. This check did not run GPU work.
- Preserved the binary and patch at `/Volumes/OPENCORE/XEGFX-HANDOFF/candidates/render-barrier-a9dfe278/`.
  The installed plugin stays disabled for WindowServer after the crash. The next GPU test needs an approved
  test boot and should compare the candidate against the current plugin in the offscreen barrier test first.

## 2026-11-22 (macOS side, private offscreen GPU comparison passed)

- At **12:02 IST**, ran XeGfx stages 1–7 in the normal AMFI boot with the global plugin temporarily parked.
  AGDC, desktop acceleration, and zero-copy remained off. Loaded both plugins privately through Intel ANV.
- Both plugins passed the Metal compute and draw probe and all seven blend, scissor, discard, and write-mask
  regression cases. The test sources only changed their build check from `24H32` to local `24H241`.
- In all four render-barrier variants, the installed plugin gave **512/1,024 wrong pixels** and read back black
  where green was expected. The candidate gave **0/1,024 wrong pixels** each time, with the expected green, and
  logged that it refreshed the render-target snapshot. The row-pitch hunk was outside this candidate and test.
- Restored the installed global plugin and verified its original hash. WindowServer remained PID 161 and its
  allow-list remained `-WindowServer`. XeGfx stage 7 stays available for private tests until reboot.
- Report: `/Volumes/OPENCORE/XEGFX-HANDOFF/reports/offscreen-renderbarrier-20261122-120212-HAhG6v/`.
  The candidate addresses the offscreen repro. Its effect on desktop artifacts and the WindowServer crash
  remains unverified.

## 2026-11-22 (macOS side, candidate CoreDisplay preflight passed)

- At **12:05 IST**, the candidate's built-in probe handed untranslated shader data to Vulkan and reported three
  pipeline failures. At **12:06 IST**, a private test using normal Metal library, function, and pipeline APIs built
  `GPUPass`, `ColorFill`, and `TextureCopy` on the Arc 130T with both plugins. The candidate's compute and draw
  checks also passed. WindowServer stayed on the baseline desktop.
- Reports: `/Volumes/OPENCORE/XEGFX-HANDOFF/reports/metal-candidate-coredisplay-20261122-120507-85MyRk/` and
  `/Volumes/OPENCORE/XEGFX-HANDOFF/reports/coredisplay-metal-api-FejkMz/`.
- The user approved one more external OpenCore AMFI test boot. The desktop trial script restores the standard
  config on disk, backs up the global plugin, and uses the candidate with framebuffer fetch and zero-copy off.
- Staged `efi/config-xegfx-amfi-test.plist` as the current external config and verified its only difference from
  the standard XeGfx config is `amfi=0x80`. After boot and login, remount `OPENCORE` and run
  `sudo bash scripts/run-render-barrier-desktop-trial.sh --restart-windowserver` from the ESP handoff.

## 2026-11-22 (macOS side, patched desktop renders correctly and feels slow)

- Booted the approved AMFI test at **12:09:07 IST**. Restored the normal OpenCore config on disk, backed up
  the old plugin, and loaded the patched renderer. WindowServer restarted once at **12:13:15 IST** and held
  PID 1414. Framebuffer fetch was enabled for that launch. Zero-copy stayed off.
- The user confirmed that blur and transparency now look correct throughout the desktop and reported lag.
  Active counter intervals had a median of 21.1 frames/s, a 90th percentile of 29.8, and no reported presentation
  failures. One live sample showed 783 µs to copy a frame and 14,277 µs waiting for vertical blank. The framebuffer
  published `IOFBWaitCursorPeriod = 33333333` ns. Together these show 30 fps pacing and motivate an A/B test;
  they leave the limiting step unresolved.
- Activation and counters: `/Volumes/OPENCORE/XEGFX-HANDOFF/reports/desktop-on-20261122-121303-cf5O5c/`.
- Prepared `scripts/test-vblank-copy.sh` and checked its three timing phases and restoration with mock counters.
  Automatic approval review hit its usage limit before the live test ran. The current timing settings stayed as they were.

## 2026-11-22 (macOS side, vblank copy timing comparison)

- Retried successfully at **12:20 IST** during the same patched WindowServer session. The three ten-sample phases
  averaged **28.1** frames per approximately one-second sample with synchronized copies, **26.1** with immediate
  copies, and **27.4** after restoring synchronization. Immediate copying did not improve delivered frame rate.
- Verified `debug.nvaccel_iop_vblsync=1`, `debug.nvaccel_xeflip=0`, and zero presentation failures after the test.
  WindowServer remained PID 1414. The test made no persistent timing change.
- Report: `/Volumes/OPENCORE/XEGFX-HANDOFF/reports/vblank-copy-timing-20261122-122040-ewN7oF/`.

## 2026-11-22 (macOS side, completion-mark pacing candidate)

- The Intel framebuffer measured and reported **58.55 Hz** from pipe A. During the slow accelerated session
  vertical blank sync was enabled with zero misses, zero-copy was off, and `NMXAccel` advertised `NVAccelSurfaceWait`.
  The kernel's completion-mark switch was on and all mark counters remained zero. The installed renderer's
  `nvmtl_vk_surface_gpu_mark` only called the NVIDIA NVK export. Intel ANV does not expose that export.
- Built a candidate with the existing render-barrier fix plus the ThinkBook's XGDR handoff hunk. Its new Intel
  path carries pending and ready marks and recognizes `NVAccelSurfaceWait` on `NMXAccel`, so ready marks can
  be issued before publication. The ordinary-user XGDR probe returned the driver's expected refusal because
  kernel completion marks are restricted to WindowServer. The offscreen barrier test passed with zero wrong
  pixels, all three CoreDisplay pipelines built, and the live desktop was left running during these tests.
- Report: `/Volumes/OPENCORE/XEGFX-HANDOFF/reports/windowserver-pacing-preflight-pd20um/`. Next: one guarded
  WindowServer restart in the current approved boot. Keep vblank sync enabled, zero-copy off, and verify that
  completion marks arrive without timeouts before evaluating frame rate and tearing.

## 2026-11-22 (macOS side, pacing restart returned to the backup)

- The first restart at **12:27:02 IST** brought up WindowServer PID 4902. Its loaded plugin UUID and the file
  on disk both matched the prior render-barrier build, even though the staging report had recorded the pacing
  build before the restart. No completion marks reached the kernel. Vblank synchronization and blur stayed active.
- Prepared a retry with the restart output redirected to the handoff and no rollback tied to the caller exiting.
  The retry confirms and retires the old crash guard before starting a new one. Guard PIDs are now recorded in
  each activation report.
- First attempt: `/Volumes/OPENCORE/XEGFX-HANDOFF/reports/windowserver-pacing-desktop-20261122-122647-13IhLQ/`.

## 2026-11-22 (macOS side, active completion marks and frame timing)

- The guarded retry began at **12:32 IST** and loaded renderer UUID `BE0570AE-3561-38FA-9A13-9AC330FB930D`
  in WindowServer PID 6654. The renderer confirmed XGDR completion marks and delegated GPU completion to
  NVAccel. Framebuffer fetch and vblank copy synchronization were enabled. Zero-copy remained off.
- At **12:34 IST**, 15 active window-drag samples averaged **31.8 fps**, with a median of **32.6 fps** and
  a peak of **34.7 fps**. The sample accumulated zero additional completion timeouts, vblank misses, or
  presentation failures.
- An independent eight-second display-link probe reported **59.28 Hz** in CoreVideo and **58.53 Hz** in
  CoreAnimation. Core Graphics sees the panel at **1920x1200, 59 Hz**. The physical and application clocks
  can therefore both deliver near-60 Hz timing while WindowServer delivers fewer new frames.
- An automated moving-window test submitted 611 window positions in 12.020 seconds. The 13-second panel
  sample delivered 444 frames, had zero vblank misses or presentation failures, and recorded 24 additional
  GPU completion timeouts. It had 217 gaps of 15–19 ms and 163 gaps of 30–39 ms. Repeated timeouts on
  surfaces `0x2`, `0x3` and `0x6` reached the driver's 100 ms wait limit across the session.
- In a six-second WindowServer sample, 127 of 528 main-thread samples were in IOKit display transaction
  calls from CoreDisplay. Only three samples were in the renderer's `waitUntilScheduled`. The profiler
  cannot attribute IOKit time to specific kernel waits, so there may be several contributors.
- Reports: `/Volumes/OPENCORE/XEGFX-HANDOFF/reports/windowserver-pacing-desktop-20261122-123157-iWVCMw/`
  and `/Volumes/OPENCORE/XEGFX-HANDOFF/reports/desktop-on-20261122-123202-YRsuO1/`.
- The controlled three-phase comparison averaged approximately **30.5**, **27.5**, and **31.2 fps** from
  panel-counter deltas over 13 seconds with marks enabled, disabled, and restored respectively. The enabled
  phases recorded 35 and 34 completion timeouts and the disabled phase recorded zero. All phases had zero
  vblank misses and zero failed presentations. Restored marks, synchronized copies and zero-copy disabled.
  The miss counter tracks copies that failed to find a vblank. A refresh with no submitted frame does not
  increment it, and the counter does not measure visible tearing.
- Built a renderer with the same barrier and XGDR patches plus the upstream WindowServer timing diagnostics.
  The diagnostics report commit-to-GPU delay, GPU execution, and GPU-end-to-completion latency, along with
  counts of command buffers that still hold a marked surface. The new build passed signature verification,
  the offscreen render-barrier test and all three CoreDisplay pipeline checks. The user authorized one guarded
  WindowServer restart to capture this data in the active boot.
- Saved the build and diagnostics patch under `candidates/render-barrier-pacing-timing-a9dfe278`. The
  installation report is `reports/windowserver-frame-timing-20261122-124327-3s2jJF/`. Its previous-plugin file
  locates the verified pacing build for rollback. Activation initially stopped at the existing allow-list,
  leaving PID 6654 running. The retry checks both hashes, re-arms only WindowServer and uses the crash guard.

## 2026-11-22 (macOS side, GPU execution and completion timing)

- The approved WindowServer restart succeeded at **12:48:31 IST**. PID 10351 loaded UUID
  `06DFFFD9-8FAB-35E8-AD60-3E48C26E1407` and logged working XGDR marks with early surface ordering.
  The guard recorded one WindowServer restart. Report:
  `reports/desktop-on-20261122-124818-wWl4iS/` on the external handoff.
- Eight five-second timing summaries survived in the system log. In the busiest interval (379
  command buffers), commands averaged **17.0 ms** before GPU start, **5.7 ms** on the GPU, and
  **55.0 ms** from GPU end to the renderer's completion bookkeeping. One command buffer spent
  **142 ms** between GPU end and completion. These are per-command-buffer timings, including
  queueing, and cannot be read as frame rate or proof of any specific blocking call.
- The user confirmed they restarted the laptop manually while the desktop was responsive. Boot
  time was **12:52:16 IST**, and the prior boot did not leave a new panic or WindowServer crash
  report. The new boot uses the normal AMFI policy and has no active XeGfx stages.
- Next diagnostic should separate wait-for-fence, surface-ready marking and publication delays.
  Keep vertical blank synchronization and test only one graphics change per comparison.
- Recovered the persisted guard counters from the EFI. They showed 449 additional panel copies from
  12:49:33 to 12:49:49, approximately 28 per second, with zero failed presents or zero-copy flips.
  These were background guard samples without a controlled workload.
- Built the optional completion breakdown from the pinned source and verified its full bundle signature.
  It logs up to 24 slow completions, with separate times for worker availability, fence and witness,
  query and resource retirement, ready marks, and surface publication. Saved the executable and
  patch under `candidates/render-barrier-pacing-completion-a9dfe278/`. Hardware validation remains pending.
- Standard EFI mounting failed after reboot. A read-only FAT check reported extra clusters in Spotlight
  index files. A read-only mount through the kernel driver succeeded, and the full `EFI` directory was
  copied and compared before the mount was made writable. No filesystem repair was run.
- Recreated the audio trial from the verified external config. Both plists passed `plutil`, and
  `ocvalidate` 1.0.8 reported no issues. Audio loading and playback are pending a normal-security boot.
- The user authorized one more external macOS boot with `amfi=0x80` for the completion test.
- At **13:01 IST**, staged and re-read the validated test config on the external EFI. The only difference
  from the normal config is `amfi=0x80`. Normal backup:
  `efi/backups/config-before-completion-20261122-130153.plist`. Staging report:
  `reports/completion-test-boot-20261122-130153-BMc2mQ/`. On the next login, restore the normal config on
  disk before starting XeGfx and installing the new probe. The active renderer was left in place.

## 2026-11-22 (macOS side, Safari playback freeze)

- The machine booted the authorized config at **13:06 IST**. The user reported a display freeze
  during YouTube playback in Safari and hard-rebooted at **13:08:55 IST**. The installed
  XeGfxIntelFB 0.9.4 framebuffer had attached at 1920x1200 and reported a 58.51 Hz VBL source.
  No new stage run, desktop activation, NVMTL load, WindowServer crash report, or kernel panic
  report was found for that boot. The new completion probe had not been installed or run.
- At **13:08:02 IST**, Safari's WebKit GPU service reported that its video renderer entered the
  rendering state. Its audio renderer repeatedly failed to initialize Default-Output with
  `kAudioQueueErr_InvalidDevice` (`-66680`), then logged audio renderer errors. System Information
  also reports no audio devices. The logs do not establish whether the audio errors caused the
  display freeze.
- A synthetic offscreen H.264 round trip with hardware encode and decode explicitly disabled
  decoded **30 of 30** frames. VideoToolbox reported no hardware decode availability for H.264,
  HEVC, VP9, or AV1 in the recovery session. The test omitted audio and display presentation.
- Verified and restored the backed-up normal config on the external EFI. The running boot still
  has `amfi=0x80` from the earlier config. The following external macOS boot uses normal AMFI.
- Preserved the playback and framebuffer excerpts under
  `reports/safari-freeze-20261122-131602-V8PYJT/` on the external EFI. Recreated the audio trial from
  the normal config and archived it separately under `candidates/audio-sn6140-voodoohda-3.7.1-alpha/`.
- At **13:16 IST**, the recovery boot passed XeGfx stages 1–7. The private completion probe
  (UUID `F81A79B3-7CE6-32C7-834C-1AC35359489F`) passed Metal compute with zero mismatches
  and the offscreen draw pixel checks. All three CoreDisplay pipelines built. WindowServer
  stayed PID 162 with graphics device control and display-pipe presentment off. The completion
  probe still needs a WindowServer run to measure desktop latency.

## 2026-11-22 (macOS side, zero-copy flip on the fixed renderer)

- In the same `amfi=0x80` boot, `desktop-on.sh --framebuffer-fetch` restarted WindowServer (PID 2454) with
  the render-barrier timing renderer (UUID `06DFFFD9`). At **13:38 IST**, `scripts/test-zero-copy.sh` sampled
  a window drag for 10 s with copies (**45.3 fps**) and 10 s with zero-copy (**39.2 fps**, every frame flipped,
  zero copied, kept, refused or failed). Zero-copy stayed on. By the time this was written, 7,474 frames had been
  flipped with no WindowServer restart.
- The user reported a much smoother desktop, correct blur and remaining tearing while moving windows.
- The kernel log shows WindowServer rotating surfaces `0x2`, `0x3` and `0x4` through the four GGTT slots,
  and each flip waiting up to about 13.7 ms for `PLANE_SURFLIVE`. This argues against single-buffered drawing.
  Completion timeouts rose from 20 to 34 after the test, all with matching late ready marks (mostly surface
  `0x4`). None fired during the 10 s zero-copy sample. Those are hitches on finished frames, so they don't
  explain the tear.
- Prepared read-only `scripts/read-plane-regs.sh` to check `PLANE_CTL` bit 9 (async address update, which skips
  the vblank latch) and the other plane registers through `debug.nvaccel_mmio_win`.
- Report: `reports/zero-copy-20261122-133802-tducSm/`.
- At **13:46 IST**, `read-plane-regs.sh` read `PLANE_CTL_1_A = 0x84000008` (enabled, linear, XRGB8888, async
  address update **off**). `PLANE_SURF` matched `PLANE_SURFLIVE` in all three samples, on slots `0xb8000000`
  and `0xb5000000`. The flips latch at vblank, so a flip mid-scanout can't be the cause.
  Report: `reports/plane-regs-20261122-134654.txt`.
- Remaining hypotheses: (1) WindowServer draws into the surface that is still on screen, because it gets each
  surface back when its synchronous transaction returns (copy semantics), and (2) the display engine reads
  DRAM while the GPU's newest lines are still in the LLC. `nvaccel_iop_clflush` only covers the copy path.
  Distinguishing them needs a rebuilt XeGfxAccel with an xeflip front-surface draw counter and an optional
  clflush before each flip.

## 2026-11-22 (macOS side, XeGfxAccel tear-diagnostic build)

- Rebuilt XeGfxAccel from WTLIntelGfx `a3fd73ed` (v0.0.47) with samwu07's `wtl-worktree.patch`, then
  `xeflip`, `gpufb`, `wsmark` and `backlight` (their `7-xeflip.sh` order), NVIDIA 615.78.08 headers, the
  15.5 SDK and Apple clang 17. Built without `-DNM_TAHOE`. The stock build's string table equals the installed
  0.9.5 plus `nvaccel_backlight` (0.9.6). Same 900 undefined kernel symbols with and without the diagnostics.
  The build ran in this XeGfx boot (a 4 s single-file compile; samwu07's no-XeGfx rule traces to FbRelocate, which
  isn't used here).
- `patches/xeflip-tear-diagnostics.patch`, version 0.9.6d1, adds `debug.nvaccel_xeflip_front_draws` (pending
  marks for the surface on the panel), `_pend_marks`, `_front_id`, and an optional pre-flip `clflush` of the
  whole surface (`debug.nvaccel_xeflip_clflush`, default 0, timed in `_clflush_us`/`_us_max`). Ad hoc signed.
  Saved with the stock build under `candidates/xegfxaccel-teardiag-0.9.6d1/` (with `SHA256SUMS` and `SOURCE.txt`).
- New scripts: `install-xegfxaccel-candidate.sh` (backup, relink the AuxKC, check every kext survives,
  automatic rollback, `--restore BACKUP`) and `test-tear-diag.sh` (15 s phases with flush off, on, off again;
  restores the normal OpenCore config on disk first).
- At **13:56 IST**, staged `config-xegfx-amfi-test.plist` as the live config for the test boot (only difference
  `amfi=0x80`). Backup: `efi/backups/config-before-teardiag-20261122-135647.plist`.
- Next: install the candidate, reboot, run stages 1–7, run `desktop-on.sh --restart-windowserver --framebuffer-fetch`,
  then `test-tear-diag.sh`. Many front draws point to buffer reuse. Tearing that only goes away with the flush
  points to cache coherence.
- **Terminal blank past ~75 columns: fixed by allow-listing it.** Terminal logged "not allow-listed: no device for
  Terminal" and Core Image "No Metal renderer available". A Terminal launched with `NVMTL_ENABLE=1` kept its text
  at any width (user confirmed at **14:18 IST**). The renderer's row-pitch hunk was ruled out, because its refusal
  message never fired. The current renderer rebuilds byte-identically from the recipe (UUID `06DFFFD9`).
- `desktop-on.sh` now accepts armed-only `!App` lines next to `!WindowServer`, and its crash guard keeps them
  when it writes `-WindowServer`. New `scripts/allow-app.sh APP` adds one such line.

## 2026-11-22 (macOS side, touchpad cursor jumps)

- The user reported the touchpad cursor jumping around. The pad is the Goodix GXTP5100 on I2C0, polled
  (`-vi2c-force-polling`), the same as samwu07's ThinkBook, where single reads with one zeroed coordinate byte
  sent the cursor to the edge and back.
- Built VoodooI2CHID from VoodooI2C v2.9.1 (`e3ac3ed2`, satellite `a478fd6`, MacKernelSDK `a2ba595`) with the
  Command Line Tools only (`build-hid.sh`, no Xcode). The unpatched build imports the same 492 kernel symbols as
  the official release. With samwu07's `VoodooI2CHID-glitch-guard.patch` it adds only `_PE_parse_boot_argn`,
  `_memcmp` and `_snprintf`, as they document. The patch re-reads frames with an impossible finger jump, votes on
  touched frames, and fixes the never-idle poll. Boot-arg overrides: `-vi2c-no-glitch-guard`, `-vi2c-no-vote`,
  `vi2c-glitch-step=N`, `vi2c-idle-ms=N`.
- At **14:38 IST**, replaced `EFI/OC/Kexts/VoodooI2CHID.kext` on the ESP (all three configs use that path).
  Original and build files: `candidates/voodooi2chid-glitch-guard/` (`original/`, `SHA256SUMS`, `SOURCE.txt`,
  `cursor-watch`). A 40 s baseline recorded no movement (no swipe), so a before/after count is still pending.
- Rollback: copy `candidates/voodooi2chid-glitch-guard/original/VoodooI2CHID.kext` back over `EFI/OC/Kexts/`.
- After the reboot (**14:38 IST**) the patched kext loaded but jumps continued. `FwdJumps` recorded 53, all with 3–4
  contacts and a zeroed high byte (Y 1414→134, X 2159→111, X 1136→112). The guard's own counters never appeared:
  it requires a frame of at least 40 bytes with 7-byte slots (the ThinkBook layout). Parsing this pad's HID
  descriptor shows report 4 = 5 slots × {flags, X u16, Y u16}, scan time at payload byte 25, contact count, button:
  a 32-byte frame. The guard never ran.
- Built v2 with `glitch-guard-layout.patch` (slot size and scan offset from the frame length) and installed it on the
  ESP at **~14:55 IST**. The first build is kept in `v1-thinkbook-layout/` and the release in `original/`. The patches
  and build script are also in the repo under `touchpad/`. After rebooting, `GlitchFrames`/`Votes` should appear
  in ioreg.
- The user confirmed the v2 touchpad build works well.

## 2026-11-22 (macOS side, GPU desktop autostart)

- The user asked for the GPU desktop at every boot and approved keeping `amfi=0x80` permanently. At **15:06 IST**,
  `efi/config-xegfx.plist` and the live `EFI/OC/config.plist` became the AMFI config. Backups:
  `efi/backups/config-before-autostart-20261122-150617.plist` and `config-xegfx-noamfi-20261122-150617.plist`.
  `make_xegfx_config.py` now adds `amfi=0x80` too.
- New `scripts/autostart.sh on|off|status` and `scripts/autostart-boot.sh` (adapted from samwu07's). They are installed into
  `/Library/XeGfx/autostart/` with LaunchDaemon `org.local.xegfx-desktop`. At the login window they run stages 1–7,
  then `desktop-on.sh --restart-windowserver --framebuffer-fetch`, confirm frames after 2 minutes, then turn on
  zero-copy flip with the pre-flip clflush (the user's choice). State lives in files, not NVRAM: `pending` (an
  unconfirmed run turns autostart `off` on the next boot), `off`, `flip-off`. Skip one boot with `-xegfxnoauto`,
  or flips only with `-xegfxnoflip`. Log: `/Library/XeGfx/autostart/autostart.log`.

## 2026-11-22 (Linux side, ESP repair and repo sync)

- Backed up the whole ESP before touching it: a file copy and a raw image `~/Backups/opencore-esp-20261122-185113{,.img}`
  on the internal Arch disk.
- `fsck.fat -n` found duplicate directory entries, most likely from hard reboots while macOS was writing to the
  FAT ESP. Ran `fsck.fat -a`. It renamed one entry of each duplicate pair to `FSCK0000.*`, including live files
  (`scripts/autostart-boot.sh`, `candidates/render-barrier-pacing-timing-a9dfe278`, two report folders,
  `efi/backups/config-xegfx-noamfi-*.plist`, ...). Each one was compared byte for byte against the pre-repair copy
  and renamed back. The ESP now matches the backup exactly, apart from the deletions below, and `fsck.fat -n` is clean.
- Removed `.Spotlight-V100` (the source of most duplicates) and added `.metadata_never_index` and
  `.fseventsd/no_log`, so macOS stops indexing and journaling the ESP. Also removed two `FSCK0000.000` folders
  inside `VoodooI2C.kext` and `VoodooPS2Controller.kext` PlugIns. They came with the original 240H zip and were
  verified duplicates of VoodooI2CServices and VoodooPS2Keyboard. `tools/build_efi.py` now strips them.
- **To avoid more FAT damage:** unmount the ESP (`sudo diskutil unmount /Volumes/OPENCORE`) before rebooting
  from macOS, and don't hard-power-off while a script is writing reports to it.
- Pushed the macOS session's work to git (`accel/`): HANDOFF, LOG, START-HERE, all scripts, and the candidates'
  patches, build notes and checksums. Binaries (NVMTLDriver builds, kexts, cursor-watch), the audio-trial
  `config.plist` (it has the SMBIOS), `reports/` and `efi/` stay on the ESP only. The touchpad glitch-guard
  patches are in `accel/candidates/voodooi2chid-glitch-guard/`. The `touchpad/` folder mentioned above was in
  the macOS clone and was never pushed.

## 2026-11-22 (user report, documented from the Linux side)

- The user confirms that the GPU desktop in daily use now has all the transparency, blur and vibrancy effects,
  video wallpapers, and good, smooth compositing. README and HANDOFF were updated with a "What works" table. What
  still runs on the CPU: content of apps that aren't allow-listed, video decode (no VideoToolbox hardware decoder)
  and one-time shader translation.
