#!/bin/bash
# Что именно система отдаёт NotchHub о текущем треке.
# Запусти, включи музыку — увидишь сырые данные MediaRemote.
#
#   ./Scripts/now-playing.sh          один снимок
#   ./Scripts/now-playing.sh stream   поток обновлений (Ctrl-C для выхода)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/NotchHub.app"
PL="$APP/Contents/Resources/mediaremote-adapter.pl"
FW="$APP/Contents/Frameworks/MediaRemoteAdapter.framework"

if [ ! -f "$PL" ]; then
    echo "Сначала собери приложение: ./Scripts/build.sh" >&2
    exit 1
fi

MODE="${1:-get}"
case "$MODE" in
    stream) exec /usr/bin/perl "$PL" "$FW" stream --no-artwork ;;
    get)
        OUT=$(/usr/bin/perl "$PL" "$FW" get --no-artwork)
        if [ "$OUT" = "null" ]; then
            echo "Сейчас ничего не играет."
            echo "Включи трек в Яндекс Музыке и запусти снова —"
            echo "в поле bundleIdentifier должно быть ru.yandex.desktop.music."
        else
            echo "$OUT" | python3 -m json.tool 2>/dev/null || echo "$OUT"
        fi
        ;;
    *) echo "Использование: $0 [get|stream]" >&2; exit 2 ;;
esac
