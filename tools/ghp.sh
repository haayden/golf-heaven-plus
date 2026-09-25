#!/usr/bin/env bash
# Send a command to the running game through the GHPDev harness and print the reply.
# Usage: tools/ghp.sh ping | restart <Mod> | console <cmd> | lua '<code>' | test
# GHP_TIMEOUT (seconds, default 10) controls how long to wait for the game.
set -euo pipefail

dev_dir="$(cd "$(dirname "$0")/.." && pwd)/dev"
mkdir -p "$dev_dir"
id="$(date +%s%N)"
printf '%s\n%s' "$id" "$*" > "$dev_dir/cmd.tmp"
mv -f "$dev_dir/cmd.tmp" "$dev_dir/cmd.txt"

tries=$(( ${GHP_TIMEOUT:-10} * 10 ))
for _ in $(seq 1 "$tries"); do
    if [ -f "$dev_dir/out.txt" ] && [ "$(head -n 1 "$dev_dir/out.txt" | tr -d '\r')" = "$id" ]; then
        tail -n +2 "$dev_dir/out.txt"
        exit 0
    fi
    sleep 0.1
done
echo "ghp: no reply within ${GHP_TIMEOUT:-10}s (is the game running with GHPDev enabled?)" >&2
exit 1
