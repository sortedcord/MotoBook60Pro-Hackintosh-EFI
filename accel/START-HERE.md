# Start here (macOS side)

1. In macOS, mount the USB EFI partition:
   ```
   sudo diskutil mount $(diskutil list external | awk '/OPENCORE/{print $NF}')
   ```
   It appears as `/Volumes/OPENCORE`. The handoff is in `/Volumes/OPENCORE/XEGFX-HANDOFF/`.
2. Get the repo for the scripts (or use the copy on the ESP):
   ```
   git clone https://github.com/sortedcord/MotoBook60Pro-225H-Hackintosh-EFI ~/MotoBook60Pro-225H-Hackintosh-EFI
   ```
   Run the scripts **from the ESP copy** (`/Volumes/OPENCORE/XEGFX-HANDOFF/scripts/`). They write their reports
   next to it, where the Linux side can read them too.
3. Start the agent and paste this:

> You are continuing a Hackintosh bring-up on a Motorola moto book 60 pro (Core Ultra 5 225H, Arc 130T iGPU
> `8086:7D51`), now running macOS Sequoia from a USB SSD with OpenCore. The goal is GPU acceleration through the
> experimental WTLIntelGfx/XeGfx driver stack. Read `/Volumes/OPENCORE/XEGFX-HANDOFF/HANDOFF.md` completely first.
> It has the machine state, the gate-by-gate plan, the pitfalls others hit, the downloads already on the ESP, and
> how to roll back. Read the newest entry in `/Volumes/OPENCORE/XEGFX-HANDOFF/LOG.md` to resume at the next step.
> Work one reversible step at a time, one reboot per change. Save every
> report under `/Volumes/OPENCORE/XEGFX-HANDOFF/reports/` and `sync` before any step that could hang. Add a dated
> entry to `/Volumes/OPENCORE/XEGFX-HANDOFF/LOG.md` after each step (what you ran, the result, the next step), so
> the next session or the Linux side can pick up from there.
