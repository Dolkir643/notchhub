#!/bin/bash
# Собрать образ NotchHub-<версия>.dmg для установки на другие маки.
#
# Приложение собирается универсальным (arm64 + x86_64): на Apple Silicon
# системный perl запускается как arm64 и x86-фреймворк адаптера не загрузит.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/NotchHub.app"
STAGE="$ROOT/build/dmg-stage"

say() { printf "\033[1;34m==>\033[0m %s\n" "$1"; }

# 1. Универсальная сборка -----------------------------------------------------
UNIVERSAL=1 "$ROOT/Scripts/build.sh"

ARCHS="$(lipo -archs "$APP/Contents/MacOS/NotchHub")"
case "$ARCHS" in
    *arm64*) : ;;
    *) echo "Собралось только под $ARCHS — на Apple Silicon работать не будет." >&2; exit 1 ;;
esac
say "Архитектуры приложения: $ARCHS"
say "Архитектуры адаптера:   $(lipo -archs "$APP/Contents/Frameworks/MediaRemoteAdapter.framework/MediaRemoteAdapter")"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
# Имя, подпись тома и оговорки в записке зависят от того, под какую систему собрали.
if [ "${MACOS11:-0}" = "1" ]; then
    DMG="$ROOT/build/NotchHub-$VERSION-macOS11.dmg"
    VOLNAME="NotchHub $VERSION (macOS 11)"
    LEGACY_NOTE="
ОСОБЕННОСТИ СБОРКИ ДЛЯ СТАРЫХ СИСТЕМ
    • вкладки «Переводчик» нет — системный переводчик появился в macOS 15;
    • на macOS 11–12 автозапуск делается своим LaunchAgent и не показывается
      в «Объектах входа»;
    • на macOS 11 нет автофокуса в полях ввода — кликните в поле мышью.
"
else
    DMG="$ROOT/build/NotchHub-$VERSION.dmg"
    VOLNAME="NotchHub $VERSION"
    LEGACY_NOTE=""
fi

# 2. Содержимое образа --------------------------------------------------------
say "Готовлю содержимое"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/Прочти меня.txt" <<EOF
NotchHub $VERSION ($BUILD)
Хаб в чёлке: музыка, полка для файлов, история буфера, заготовки,
календарь и переводчик. Требуется macOS $(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist") или новее.

УСТАНОВКА
1. Перетащи NotchHub в папку «Программы» (ярлык рядом).
2. Первый запуск: правый клик по NotchHub → «Открыть» → «Открыть».

    Обычным двойным кликом macOS его не пустит и напишет, что не может
    проверить разработчика. Это не поломка: у сборки нет платной подписи
    Apple. Если после «Открыть» всё равно блокирует — Системные настройки →
    «Конфиденциальность и безопасность», пролистай вниз, там будет кнопка
    «Всё равно открыть».

    Совсем упрямый случай лечится одной командой в Терминале:
        xattr -dr com.apple.quarantine /Applications/NotchHub.app

3. Иконки в Dock нет — это нормально. Наведи курсор на верх экрана,
   по центру строки меню, и панель раскроется.

НАСТРОЙКА
    Автозапуск, время жизни файлов на полке и размер истории буфера —
    во вкладке «Настройки» (шестерёнка внизу колонки). Оттуда же выход.

РАЗРЕШЕНИЯ
    Календарь спросит доступ по кнопке во вкладке «Календарь».
    Музыка, полка и буфер работают без разрешений.

ЧТО УМЕЕТ МУЗЫКА
    Показывает и переключает то, что играет: Яндекс Музыка, Spotify,
    «Музыка», YouTube в браузере — всё, что сообщает системе название трека.
$LEGACY_NOTE
EOF

# 3. Образ --------------------------------------------------------------------
say "Собираю $DMG"
rm -f "$DMG"
hdiutil create \
    -volname "$VOLNAME" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov "$DMG" >/dev/null

rm -rf "$STAGE"

say "Проверяю образ"
hdiutil verify "$DMG" >/dev/null && echo "    контрольная сумма в порядке"

SIZE="$(du -h "$DMG" | cut -f1)"
say "Готово: $DMG ($SIZE)"
echo "    Внутри: NotchHub.app, ярлык «Программы», «Прочти меня.txt»"
echo "    Подпись ad-hoc, без нотаризации — первый запуск через правый клик → «Открыть»."
