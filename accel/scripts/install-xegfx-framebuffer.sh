#!/bin/bash
# Prepare the Intel framebuffer for the next boot after the private Metal probe passes.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
exec /bin/bash "$here/install-xegfx-desktop-component.sh" framebuffer
