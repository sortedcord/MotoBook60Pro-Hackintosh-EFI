#!/bin/bash
# autostart.sh on|off|status -- start the Intel GPU desktop by itself at every boot (see autostart-boot.sh).
#   sudo bash autostart.sh on       copies the scripts to /Library/XeGfx/autostart and installs the LaunchDaemon;
#                                   takes effect at the next boot (it never restarts WindowServer under you now)
#   sudo bash autostart.sh off      removes the LaunchDaemon (the copied scripts and logs stay)
#   bash autostart.sh status
# Skip one boot: add -xegfxnoauto to the boot-args in the OpenCore picker, or boot Safe Mode.
# Flip without the autostart for one boot: -xegfxnoflip. Never flip: sudo touch /Library/XeGfx/autostart/flip-off
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
D=/Library/XeGfx/autostart; LBL=org.local.xegfx-desktop; PL=/Library/LaunchDaemons/$LBL.plist
case "${1:-status}" in
  status)
    if [ -f "$PL" ]; then echo "autostart: installed ($PL)"; else echo "autostart: not installed"; fi
    [ -e "$D/off" ] && echo "  switched OFF by its guard or by you ($D/off): sudo bash $0 on"
    [ -e "$D/pending" ] && echo "  a start is in progress or was never confirmed: $(cat "$D/pending.info" 2>/dev/null)"
    [ -e "$D/flip-off" ] && echo "  zero-copy flip disabled ($D/flip-off)"
    echo "  now: stage $(sysctl -n debug.xegfx_stage 2>/dev/null || echo -), accel $(sysctl -n debug.nvaccelfb 2>/dev/null || echo -)," \
         "flip $(sysctl -n debug.nvaccel_xeflip 2>/dev/null || echo -), flush $(sysctl -n debug.nvaccel_xeflip_clflush 2>/dev/null || echo -)," \
         "$(sysctl -n debug.nvaccel_xeflip_flips 2>/dev/null || echo -) flips of $(sysctl -n debug.nvaccel_iop_ok_h4 2>/dev/null || echo -) frames"
    echo "  last log lines:"; tail -8 "$D/autostart.log" 2>/dev/null | sed 's/^/    /' || true
    ;;
  on)
    [ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 2; }
    for f in autostart-boot.sh run-xegfx-stages.sh desktop-on.sh autostart.sh; do
      [ -f "$HERE/$f" ] || { echo "missing $HERE/$f" >&2; exit 1; }
      bash -n "$HERE/$f" || { echo "$f has a syntax error" >&2; exit 1; }
    done
    mkdir -p "$D/scripts" "$D/reports"
    for f in autostart-boot.sh run-xegfx-stages.sh desktop-on.sh autostart.sh; do
      install -o root -g wheel -m 755 "$HERE/$f" "$D/scripts/$f"
    done
    tmp=$(mktemp /Library/LaunchDaemons/.xegfx.XXXXXX)
    cat > "$tmp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LBL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>$D/scripts/autostart-boot.sh</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>LaunchOnlyOnce</key>
	<true/>
	<key>StandardOutPath</key>
	<string>$D/launchd.log</string>
	<key>StandardErrorPath</key>
	<string>$D/launchd.log</string>
</dict>
</plist>
EOF
    plutil -lint "$tmp" > /dev/null || { rm -f "$tmp"; echo "the plist did not validate; nothing installed" >&2; exit 1; }
    chown root:wheel "$tmp"; chmod 644 "$tmp"; mv -f "$tmp" "$PL"
    rm -f "$D/off" "$D/pending"
    sync
    echo "autostart is ON from the next boot: at the login window the screen goes dark once (WindowServer moves to"
    echo "the GPU) -- log in after that. Log: $D/autostart.log   Status: bash $D/scripts/autostart.sh status"
    case " $(sysctl -n kern.bootargs) " in *" amfi=0x80 "*) ;; *) echo "NOTE: this boot has no amfi=0x80; the autostart only runs in boots that do." ;; esac
    ;;
  off)
    [ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 2; }
    launchctl bootout system "$PL" > /dev/null 2>&1 || true
    rm -f "$PL"; sync
    echo "autostart removed (scripts and logs stay in $D). This boot is unchanged."
    ;;
  *) echo "usage: $0 on|off|status" >&2; exit 2 ;;
esac
