#!/bin/bash
# Arm XeGfx for WindowServer, then restart the graphical session after the checks pass.
# Runtime sequence and crash-loop guard adapted from samwu07/xegfx-thinkbook14plus-mtl (BSD-2-Clause).
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin

die() { echo "desktop-on: $*" >&2; exit 1; }
[ "${1:-}" = --restart-windowserver ] || die "save your work, then run with --restart-windowserver [--framebuffer-fetch [--already-armed]]"
case "${2:-}" in
  ''|--framebuffer-fetch) ;;
  *) die "unknown option $2" ;;
esac
case "${3:-}" in
  ''|--already-armed) ;;
  *) die "unknown option $3" ;;
esac
[ "$(id -u)" = 0 ] || die "run with sudo"
handoff=$(cd "$(dirname "$0")/.." && pwd)
gpu=/Library/GPUBundles
allowlist="$gpu/nvmtl-allow.txt"
[ "$(sysctl -n debug.xegfx_stage)" = 7 ] || die "complete XeGfx stage 7 first"
codesign --verify --deep --strict "$gpu/NVMTLDriver.bundle"
# Sequoia 24H241 rejects this ad hoc plugin in WindowServer on the baseline boot.
signature=$(codesign --display --verbose=4 "$gpu/NVMTLDriver.bundle" 2>&1)
if grep -Fx 'Signature=adhoc' <<< "$signature" >/dev/null; then
  boot_args=$(sysctl -n kern.bootargs)
  case " $boot_args " in
    *' amfi=0x80 '*|*' amfi_get_out_of_my_way=1 '*|*' amfi_get_out_of_my_way=0x1 '*) ;;
    *) die "the current boot rejects this ad hoc plugin in WindowServer; see the library-validation crash in LOG.md" ;;
  esac
fi
[ "$(sysctl -n debug.nvaccel_xeflip)" = 0 ] || die "turn off zero-copy before restarting WindowServer"
# '!WindowServer' plus optional armed-only app lines such as '!Terminal' (apps that need a Metal device to draw)
grep -Fx '!WindowServer' "$allowlist" >/dev/null || die "expected !WindowServer in the allow-list"
if grep -Evx '![A-Za-z0-9._ -]+' "$allowlist" >/dev/null; then die "the allow-list may only hold !App lines"; fi
kmutil showloaded --list-only | grep -F 'org.watchthelight.XeGfxAGDC (' >/dev/null || die "XeGfxAGDC is not loaded"
ioreg -r -c NMXAccel -d 1 | grep -F 'class NMXAccel' >/dev/null || die "NMXAccel is not attached"
panel=$(ioreg -l -r -c XeGfxIntelFramebuffer -d 2)
grep -F 'display0' <<< "$panel" >/dev/null && grep -F '"NVRMTiming"' <<< "$panel" >/dev/null \
  || die "the Intel framebuffer is missing the panel or its timing"
old=$(pgrep -xo WindowServer) || die "cannot find the running WindowServer"

report=$(mktemp -d "$handoff/reports/desktop-on-$(date +%Y%m%d-%H%M%S)-XXXXXX")
echo "Reports: $report"
printf '%s\n' "$panel" > "$report/panel.txt"
printf '%s\n' "$old" > "$report/windowserver-before.txt"
plugin_log=/private/tmp/nvmtl.log
if [ "${2:-}" = --framebuffer-fetch ]; then
  plugin_log="/private/tmp/nvmtl-$(basename "$report").log"
fi
printf '%s\n' "$plugin_log" > "$report/plugin-log-path.txt"
exec > "$report/activation.log" 2>&1

disarm() {
  local replacement
  replacement=$(mktemp "$gpu/.nvmtl-allow.XXXXXX") || return 1
  # deny WindowServer only; the armed-only app lines stay
  { printf '%s\n' '-WindowServer'; grep -Fvx -e '!WindowServer' -e '-WindowServer' "$allowlist" || true; } > "$replacement" \
    && chmod 644 "$replacement" && mv -f "$replacement" "$allowlist"
}
arming=0
on_error() {
  local rc=$?
  trap - EXIT
  if [ "$rc" -ne 0 ] && [ "$arming" = 1 ]; then disarm || true; fi
  sync
  exit "$rc"
}
trap on_error EXIT

if [ "${3:-}" = --already-armed ]; then
  for key in debug.xegfx_agdc debug.xegfx_agdc_k5 debug.nvaccelfb debug.nvaccel_iop; do
    [ "$(sysctl -n "$key")" = 1 ] || die "existing desktop requires $key=1"
  done
else
  echo "Activating graphics device control"
  sync
  sysctl -w debug.xegfx_agdc=1
  for attempt in {1..10}; do
    [ "$(sysctl -n debug.xegfx_agdc)" = 1 ] && break
    sleep 0.5
  done
  [ "$(sysctl -n debug.xegfx_agdc)" = 1 ] || die "AGDC did not activate"
  sysctl -w debug.xegfx_agdc_k5=1

  echo "Registering the Intel framebuffer and enabling display-pipe transactions"
  arming=1
  sync
  sysctl -w debug.nvaccelfb=1
  sleep 1
  sysctl -w debug.nvaccelfb=3
  [ "$(sysctl -n debug.nvaccelfb)" = 1 ] || die "the accelerator did not arm"
  sysctl -w debug.nvaccel_iop=1
  [ "$(sysctl -n debug.nvaccel_iop)" = 1 ] || die "the accelerator did not enable display-pipe transactions"
fi

counters=(debug.nvaccel_pipe_perform debug.nvaccel_iop_ok debug.nvaccel_iop_ok_h4 debug.nvaccel_iop_fail debug.nvaccel_iop_flips)
sysctl debug.xegfx_stage debug.xegfx_agdc debug.xegfx_agdc_k5 debug.nvaccelfb debug.nvaccel_iop \
  "${counters[@]}" > "$report/before-restart.txt"
sync

(
  trap - EXIT
  trap '' HUP
  last=$old starts=0
  echo "$(date +%T) monitoring WindowServer PID $last"
  for second in {1..600}; do
    if [ $((second % 5)) = 1 ]; then
      { date +%T; sysctl "${counters[@]}"; } >> "$report/counters.log" 2>&1 || true
      if [ -f "$plugin_log" ] && [ ! -L "$plugin_log" ] &&
         [ "$(stat -f '%Su' "$plugin_log")" = _windowserver ]; then
        tail -240 "$plugin_log" > "$report/plugin-log-tail.txt" || true
      fi
    fi
    current=$(pgrep -xo WindowServer) || current=""
    if [ -n "$current" ] && [ "$current" != "$last" ]; then
      starts=$((starts + 1))
      echo "$(date +%T) WindowServer start $starts, PID $current"
      last=$current
      sync
    fi
    if [ "$starts" -gt 1 ]; then
      disarm && echo "$(date +%T) denied WindowServer in the plugin allow-list; reboot if WindowServer still crashes"
      sync
      exit 0
    fi
    sleep 1
  done
  echo "$(date +%T) monitor finished after $starts WindowServer starts"
  sync
) </dev/null > "$report/guard.log" 2>&1 &
printf '%s\n' "$!" > "$report/guard.pid"
disown

if [ "${2:-}" = --framebuffer-fetch ]; then
  launchctl debug system/com.apple.WindowServer --environment NVMTL_FBFETCH_WS=1 "NVMTL_LOG_PATH=$plugin_log"
  echo "Framebuffer fetch configured for the next WindowServer launch"
fi
echo "Restarting WindowServer PID $old"
sync
kill -TERM "$old"
sleep 5
current=$(pgrep -xo WindowServer) || current=""
if [ "$current" = "$old" ]; then launchctl kickstart -k system/com.apple.WindowServer; fi
arming=0
echo "Log back in and check display-pipe counters in $report/counters.log"
