#!/bin/bash
# Пересобрать и перезапустить NotchHub.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pkill -x NotchHub 2>/dev/null || true
"$ROOT/Scripts/build.sh"
open "$ROOT/build/NotchHub.app"
sleep 1
if pgrep -x NotchHub >/dev/null; then
    echo "NotchHub работает (pid $(pgrep -x NotchHub))"
else
    echo "NotchHub не запустился — смотри: log show --predicate 'subsystem == \"name.notchhub.NotchHub\"' --last 2m"
    exit 1
fi
