#!/usr/bin/env bash
# Send a command to the running game through the GHPDev harness and print the reply.
# Usage: tools/ghp.sh ping | restart <Mod> | console <cmd> | lua '<code>' | test
# GHP_TIMEOUT (seconds, default 10) controls how long to wait for the game.
# The harness has one command slot, so a command overwritten by another caller before the game
# read it is sent again.
set -euo pipefail

dev_dir="$(cd "$(dirname "$0")/.." && pwd)/dev"
mkdir -p "$dev_dir"
id="$(date +%s%N)$$"

send() {
    printf '%s\n%s' "$id" "$1" > "$dev_dir/cmd.$id.tmp"
    mv -f "$dev_dir/cmd.$id.tmp" "$dev_dir/cmd.txt"
}

send "$*"
tries=$(( ${GHP_TIMEOUT:-10} * 10 ))
for i in $(seq 1 "$tries"); do
    if [ -f "$dev_dir/out.txt" ] && [ "$(head -n 1 "$dev_dir/out.txt" | tr -d '\r')" = "$id" ]; then
        tail -n +2 "$dev_dir/out.txt"
        exit 0
    fi
    if (( i % 10 == 0 )) && [ "$(head -n 1 "$dev_dir/cmd.txt" 2>/dev/null | tr -d '\r')" != "$id" ]; then
        send "$*"
    fi
    sleep 0.1
done
echo "ghp: no reply within ${GHP_TIMEOUT:-10}s (is the game running with GHPDev enabled?)" >&2
exit 1
