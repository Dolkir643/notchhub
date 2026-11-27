#!/bin/bash
# Пересобрать и перезапустить NotchHub.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

check_version() {
    /usr/bin/python3 "$ROOT/Scripts/check-install-version.py" "$1" /Applications/NotchHub.app
}
check_version "$ROOT/Resources/Info.plist"
LOCK="$(getconf DARWIN_USER_TEMP_DIR)/name.notchhub.install.lock"
/usr/bin/shlock -p "$$" -f "$LOCK" || { echo "Другой процесс уже обновляет NotchHub." >&2; exit 1; }
trap 'rm -f "$LOCK"' EXIT
"$ROOT/Scripts/build.sh"
check_version "$ROOT/build/NotchHub.app/Contents/Info.plist"
pkill -x NotchHub 2>/dev/null || true
for attempt in {1..150}; do
    pgrep -x NotchHub >/dev/null || break
    sleep 0.1
done
if pgrep -x NotchHub >/dev/null; then
    echo "NotchHub ещё сохраняет данные или восстанавливает сон. Запуск другой копии остановлен." >&2
    exit 1
fi
open "$ROOT/build/NotchHub.app"
sleep 1
if pgrep -x NotchHub >/dev/null; then
    echo "NotchHub работает (pid $(pgrep -x NotchHub))"
else
    echo "NotchHub не запустился — смотри: log show --predicate 'subsystem == \"name.notchhub.NotchHub\"' --last 2m"
    exit 1
fi
