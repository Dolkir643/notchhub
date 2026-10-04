#!/bin/bash
# Проверить новую сборку, затем заменить приложение с сохранением отката.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/build/NotchHub.app"
DST="/Applications/NotchHub.app"
STAGE="$(mktemp -d /Applications/.NotchHub-install.XXXXXX)"
BACKUP="/Applications/NotchHub.previous.app"
REPLACED=0
cleanup() {
    result=$?
    if [ "$result" -ne 0 ] && [ "$REPLACED" = 1 ] && [ -d "$BACKUP" ]; then
        pkill -x NotchHub 2>/dev/null || true
        sleep 1
        rm -rf "$DST"
        mv "$BACKUP" "$DST"
        open "$DST" || true
        echo "Восстановлена предыдущая версия." >&2
    fi
    rm -rf "$STAGE"
}
trap cleanup EXIT
# Сохраняем профиль уже установленного приложения, если не задан явно.
if [ -z "${NOTCHHUB_VARIANT:-}" ] && [ -f "$DST/Contents/Info.plist" ]; then
    NOTCHHUB_VARIANT="$(/usr/libexec/PlistBuddy -c 'Print :NotchHubVariant' "$DST/Contents/Info.plist")"
    export NOTCHHUB_VARIANT
fi
"$ROOT/Scripts/build.sh"
ditto "$SRC" "$STAGE/NotchHub.app"
codesign --verify --deep --strict "$STAGE/NotchHub.app"
pkill -x NotchHub 2>/dev/null || true
for attempt in {1..50}; do
    pgrep -x NotchHub >/dev/null || break
    sleep 0.1
done
if pgrep -x NotchHub >/dev/null; then
    echo "Приложение ещё сохраняет данные. Установка остановлена; старая версия на месте." >&2
    exit 1
fi
if [ -d "$DST" ]; then
    rm -rf "$BACKUP"
    mv "$DST" "$BACKUP"
fi
REPLACED=1
mv "$STAGE/NotchHub.app" "$DST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DST" 2>/dev/null || true
open "$DST"
sleep 3
pgrep -x NotchHub >/dev/null || { echo "Новая версия не запустилась." >&2; exit 1; }
echo "Установлено: $DST. Предыдущая версия: $BACKUP"
