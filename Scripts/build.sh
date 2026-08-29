#!/bin/bash
# Сборка NotchHub.app: адаптер MediaRemote (cmake) + SwiftPM + упаковка бандла + ad-hoc подпись.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-release}"
APP="$ROOT/build/NotchHub.app"

# xcode-select смотрит на CommandLineTools, поэтому берём Xcode переменной окружения.
if [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

say() { printf "\033[1;34m==>\033[0m %s\n" "$1"; }

# 1. Адаптер MediaRemote ------------------------------------------------------
ADAPTER_SRC="$ROOT/Vendor/mediaremote-adapter"
ADAPTER_BUILD="$ROOT/build/adapter"
if [ ! -f "$ADAPTER_BUILD/MediaRemoteAdapter.framework/MediaRemoteAdapter" ]; then
    say "Собираю MediaRemoteAdapter.framework"
    # Обе архитектуры явно: на Apple Silicon системный perl запускается как arm64
    # и x86-фреймворк просто не загрузит — музыка молча отвалится.
    # Без явной цели cmake берёт версию хозяйской системы: собранный на macOS 26
    # фреймворк на маке с 14–15 просто не загрузится, и музыка отвалится молча,
    # хотя само приложение заявляет 14.0.
    cmake -S "$ADAPTER_SRC" -B "$ADAPTER_BUILD" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 >/dev/null
    cmake --build "$ADAPTER_BUILD" >/dev/null
else
    say "MediaRemoteAdapter.framework уже собран"
fi

# 2. Swift --------------------------------------------------------------------
# UNIVERSAL=1 — собрать под обе архитектуры (для раздачи на другие маки).
# По умолчанию только своя: универсальная сборка вдвое дольше.
ARCH_FLAGS=()
if [ "${UNIVERSAL:-0}" = "1" ]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
    say "swift build -c $CONFIG (arm64 + x86_64)"
else
    say "swift build -c $CONFIG"
fi
cd "$ROOT"
swift build -c "$CONFIG" "${ARCH_FLAGS[@]}"
BIN="$(swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --show-bin-path)/NotchHub"

# 3. Бандл --------------------------------------------------------------------
say "Собираю $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp "$BIN" "$APP/Contents/MacOS/NotchHub"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

cp -R "$ADAPTER_BUILD/MediaRemoteAdapter.framework" "$APP/Contents/Frameworks/"
cp "$ADAPTER_BUILD/MediaRemoteAdapterTestClient" "$APP/Contents/Resources/"
cp "$ADAPTER_SRC/bin/mediaremote-adapter.pl" "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/MediaRemoteAdapterTestClient"

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

# 4. Подпись ------------------------------------------------------------------
say "Подписываю ad-hoc"
codesign --force --sign - --timestamp=none "$APP/Contents/Frameworks/MediaRemoteAdapter.framework" >/dev/null 2>&1
codesign --force --sign - --timestamp=none "$APP/Contents/Resources/MediaRemoteAdapterTestClient" >/dev/null 2>&1
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1
codesign --verify --verbose=1 "$APP" 2>&1 | tail -2 || true

say "Готово: $APP"
