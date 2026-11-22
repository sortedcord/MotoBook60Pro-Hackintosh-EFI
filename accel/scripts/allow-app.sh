#!/bin/bash
# Give one app the Intel Metal device while desktop acceleration is armed: adds "!APP" to the plugin allow-list.
#   sudo bash allow-app.sh Terminal        then quit and reopen the app
set -euo pipefail
app=${1:-}
[[ "$app" =~ ^[A-Za-z0-9._\ -]+$ ]] || { echo "usage: sudo bash $0 AppProcessName" >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
list=/Library/GPUBundles/nvmtl-allow.txt
grep -Fx "!$app" "$list" >/dev/null || printf '%s\n' "!$app" >> "$list"
cat "$list"
