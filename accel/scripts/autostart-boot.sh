#!/bin/bash
# autostart-boot.sh -- run once per boot by launchd (org.local.xegfx-desktop, installed by autostart.sh into
# /Library/XeGfx/autostart/scripts/). Brings up the Intel GPU desktop at the login window: XeGfx stages 1-7,
# desktop-on.sh (one WindowServer restart before anyone logs in), then zero-copy flips with the pre-flip cache flush.
# Adapted from samwu07/xegfx-thinkbook14plus-mtl metal-stack/desktop/autostart-boot.sh (BSD-2-Clause). Differences:
# scripts and reports live on the system disk (the ESP is not mounted at boot), state lives in files instead of NVRAM
# (this firmware's NVRAM writes run in SMM; see HANDOFF.md), and the flush (XeGfxAccel 0.9.6d1) follows the flip.
#
# It does nothing unless every condition holds, and a run that is not confirmed blocks the next one:
#   - not Safe Mode, no boot-arg -xegfxnoauto, no $D/off, and amfi=0x80 in the boot-args
#   - XeGfx is loaded (injected by OpenCore) and the GPU is the Arc 130T
#   - the previous run was confirmed ($D/pending is gone). A boot that hung, panicked or was cut with the power button
#     leaves it: the next boot turns autostart off (sudo bash autostart.sh on re-enables it)
#   - nobody is logged in yet when WindowServer would restart
# Confirmed = 2 minutes after the restart, frames reach the panel and WindowServer started at most once.
# Flip: on a confirmed desktop only. Off for one boot: boot-arg -xegfxnoflip. Off for good: $D/flip-off.
PATH=/usr/bin:/bin:/usr/sbin:/sbin
D=/Library/XeGfx/autostart; S=$D/scripts; L=$D/autostart.log
log() { echo "$(date '+%F %T') $*" >> "$L"; }
off() { touch "$D/off"; log "autostart switched OFF: $*  (re-enable: sudo bash $S/autostart.sh on)"; sync; exit 0; }
mkdir -p "$D/reports"
[ -f "$L" ] && tail -400 "$L" > "$L.tmp" 2>/dev/null && mv -f "$L.tmp" "$L"
# keep the newest 8 report folders of each kind
for kind in stages desktop-on; do
  ls -td "$D/reports/$kind"-* 2>/dev/null | tail -n +9 | while IFS= read -r old; do rm -rf "$old"; done
done
log "boot $(sysctl -n kern.boottime | sed -E 's/.*\} //')"

[ -e "$D/off" ] && { log "off ($D/off exists): nothing done"; exit 0; }
[ "$(sysctl -n kern.safeboot 2>/dev/null)" = 1 ] && { log "Safe Mode: nothing done"; exit 0; }
args=" $(sysctl -n kern.bootargs) "
case "$args" in *" -xegfxnoauto "*) log "boot-arg -xegfxnoauto: nothing done"; exit 0 ;; esac
case "$args" in *" amfi=0x80 "*) ;; *) log "no amfi=0x80 in the boot-args: WindowServer would reject the plugin; nothing done"; exit 0 ;; esac
if [ -e "$D/pending" ]; then
  rm -f "$D/pending"
  off "the previous automatic start was never confirmed ($(cat "$D/pending.info" 2>/dev/null))"
fi
# OpenCore injects XeGfx into the boot collection, idle: the stages script loads it. No grep -q after a pipe (SIGPIPE).
kmutil showloaded --show all --collection boot --list-only 2>/dev/null | grep -F 'org.watchthelight.XeGfx (' > /dev/null \
  || { log "XeGfx is not in this boot's kernel collection (not the XeGfx OpenCore config): nothing done"; exit 0; }

# WindowServer must be up, and XeGfxIntelFB's framebuffer gets the panel (display0) only once WindowServer opened it
for i in $(seq 1 90); do pgrep -x WindowServer > /dev/null && break; sleep 2; done
for i in $(seq 1 60); do ioreg -r -c XeGfxIntelFramebuffer -d 2 | grep -F 'display0' > /dev/null && break; sleep 2; done
ioreg -r -c XeGfxIntelFramebuffer -d 2 | grep -F 'display0' > /dev/null \
  || { log "the panel did not reach XeGfxIntelFramebuffer in 2 minutes: nothing done"; exit 0; }

if [ "$(sysctl -n debug.xegfx_stage 2>/dev/null)" != 7 ]; then
  log "running XeGfx stages 1-7"
  printf 'stages started %s\n' "$(date '+%F %T')" > "$D/pending.info"; touch "$D/pending"; sync
  bash "$S/run-xegfx-stages.sh" 7 > "$D/stages-last.log" 2>&1
  rm -f "$D/pending"; sync
  [ "$(sysctl -n debug.xegfx_stage 2>/dev/null)" = 7 ] \
    || off "stages stopped at $(sysctl -n debug.xegfx_stage 2>/dev/null): $(grep -E 'FAILED|failed' "$D/stages-last.log" | tail -1)"
  log "stages 1-7 passed"
fi

cu=$(stat -f %Su /dev/console 2>/dev/null)
case "$cu" in ""|root|_*) ;; *) log "$cu logged in before the start: skipped (run desktop-on.sh by hand)"; exit 0 ;; esac

before=$(ls -td "$D/reports"/desktop-on-* 2>/dev/null | head -1)
printf 'desktop-on started %s\n' "$(date '+%F %T')" > "$D/pending.info"; touch "$D/pending"; sync
log "starting desktop-on.sh"
bash "$S/desktop-on.sh" --restart-windowserver --framebuffer-fetch > "$D/desktop-on-last.log" 2>&1
rc=$?
R=$(ls -td "$D/reports"/desktop-on-* 2>/dev/null | head -1)
if [ $rc -ne 0 ] || [ "$R" = "$before" ] || ! grep -F 'Restarting WindowServer' "$R/activation.log" > /dev/null 2>&1; then
  # desktop-on stops before the restart on a failed check (the switches it set are undone by its error trap)
  rm -f "$D/pending"; sync
  log "desktop-on.sh stopped (exit $rc) before restarting WindowServer: $(tail -1 "$D/desktop-on-last.log" 2>/dev/null)"
  exit 0
fi
log "WindowServer restarted on the GPU; report $R"
sleep 120
frames=$(sysctl -n debug.nvaccel_iop_ok_h4 2>/dev/null); frames=${frames:-0}
starts=$(grep -c 'WindowServer start [0-9]' "$R/guard.log" 2>/dev/null); starts=${starts:-0}
if [ "$frames" -gt 0 ] && [ "$starts" -le 1 ]; then
  rm -f "$D/pending"; sync
  log "confirmed: $frames frames on the panel, $starts WindowServer start(s)"
else
  rm -f "$D/pending"
  off "not confirmed after 2 minutes: $frames frames on the panel, $starts WindowServer start(s) (report $R)"
fi

case "$args" in *" -xegfxnoflip "*) log "flip: boot-arg -xegfxnoflip, left off"; sync; exit 0 ;; esac
[ -e "$D/flip-off" ] && { log "flip: $D/flip-off exists, left off"; sync; exit 0; }
ws=$(pgrep -xo WindowServer); f0=$(sysctl -n debug.nvaccel_iop_fail 2>/dev/null)
# the flush first, so the first flipped frame is already flushed (only XeGfxAccel 0.9.6d1 has it)
if sysctl -w debug.nvaccel_xeflip_clflush=1 > /dev/null 2>&1; then flush=on; else flush="not available"; fi
sysctl -w debug.nvaccel_xeflip=1 > /dev/null 2>&1
g=$(sysctl -n debug.nvaccel_xeflip_ggtt 2>/dev/null)
case "$g" in
  [1-4]" slot(s)"*) log "flip ON (cache flush $flush): $g" ;;
  *) sysctl -w debug.nvaccel_xeflip=0 > /dev/null 2>&1; log "flip: no slot placed ($g), left off for this boot"; sync; exit 0 ;;
esac
sleep 60
ws2=$(pgrep -xo WindowServer); f1=$(sysctl -n debug.nvaccel_iop_fail 2>/dev/null)
fl=$(sysctl -n debug.nvaccel_xeflip_flips 2>/dev/null); cp=$(sysctl -n debug.nvaccel_xeflip_copied 2>/dev/null)
if [ "$ws2" != "$ws" ] || [ "${f1:-0}" != "${f0:-0}" ]; then
  touch "$D/flip-off"
  log "flip problem: WindowServer $ws -> ${ws2:-none}, frame failures ${f0:-?} -> ${f1:-?}; flip-off written for later boots"
  [ "$ws2" != "$ws" ] && sysctl -w debug.nvaccel_xeflip=0 > /dev/null 2>&1
else
  log "flip confirmed: ${fl:-0} flipped, ${cp:-0} copied in the first minute"
fi
sync
