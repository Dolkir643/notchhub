#!/bin/bash
# Собрать и поставить NotchHub в /Applications.
#
# Автозапуск (SMAppService) работает только для приложения, которое система
# считает установленным: из build/ она его не видит и отвечает «not found».
# Поэтому переключатель «Запускать при входе» оживает только после установки.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/build/NotchHub.app"
DST="/Applications/NotchHub.app"

say() { printf "\033[1;34m==>\033[0m %s\n" "$1"; }

"$ROOT/Scripts/build.sh"

say "Закрываю запущенный экземпляр"
pkill -x NotchHub 2>/dev/null || true
sleep 1

say "Копирую в $DST"
rm -rf "$DST"
cp -R "$SRC" "$DST"

# Без этого система может ещё какое-то время держать старую запись
# и не найти приложение при регистрации автозапуска.
say "Регистрирую в LaunchServices"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$DST" 2>/dev/null || true

say "Запускаю"
open "$DST"
sleep 2

if pgrep -x NotchHub >/dev/null; then
    say "Готово. Дальше: наведись на островок → «Настройки» → «Запускать при входе»."
    echo "    Если macOS попросит подтвердить — Системные настройки → Основные → Объекты входа."
else
    echo "NotchHub не запустился. Логи:" >&2
    echo "  log show --predicate 'subsystem == \"name.notchhub.NotchHub\"' --last 2m" >&2
    exit 1
fi
