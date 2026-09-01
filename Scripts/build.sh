#!/bin/bash
# Сборка NotchHub.app: адаптер MediaRemote (cmake) + SwiftPM + упаковка бандла + ad-hoc подпись.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-release}"
APP="$ROOT/build/NotchHub.app"

# MACOS11=1 — сборка для Big Sur и новее. Иначе macOS 14+.
# Одни и те же исходники: различаются только минимальная система и то, что
# для старых нужно положить в бандл рантайм Swift Concurrency.
if [ "${MACOS11:-0}" = "1" ]; then
    export MACOS11=1
    MIN_MACOS=11.0
else
    MIN_MACOS=14.0
fi

# xcode-select смотрит на CommandLineTools, поэтому берём Xcode переменной окружения.
if [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

say() { printf "\033[1;34m==>\033[0m %s\n" "$1"; }

# 1. Адаптер MediaRemote ------------------------------------------------------
ADAPTER_SRC="$ROOT/Vendor/mediaremote-adapter"
ADAPTER_BUILD="$ROOT/build/adapter-$MIN_MACOS"
if [ ! -f "$ADAPTER_BUILD/MediaRemoteAdapter.framework/MediaRemoteAdapter" ]; then
    say "Собираю MediaRemoteAdapter.framework"
    # Обе архитектуры явно: на Apple Silicon системный perl запускается как arm64
    # и x86-фреймворк просто не загрузит — музыка молча отвалится.
    # Без явной цели cmake берёт версию хозяйской системы: собранный на macOS 26
    # фреймворк на более старой просто не загрузится, и музыка отвалится молча,
    # хотя само приложение заявляет минимум пониже.
    cmake -S "$ADAPTER_SRC" -B "$ADAPTER_BUILD" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS" >/dev/null
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
# `${x[@]+"${x[@]}"}` вместо простого `"${x[@]}"`: в штатном bash 3.2 из macOS
# раскрытие пустого массива под `set -u` считается обращением к незаданной
# переменной и рубит сборку. Ловится только при вызове без UNIVERSAL=1.
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/NotchHub"

# 3. Бандл --------------------------------------------------------------------
say "Собираю $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp "$BIN" "$APP/Contents/MacOS/NotchHub"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $MIN_MACOS" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

cp -R "$ADAPTER_BUILD/MediaRemoteAdapter.framework" "$APP/Contents/Frameworks/"
cp "$ADAPTER_BUILD/MediaRemoteAdapterTestClient" "$APP/Contents/Resources/"
cp "$ADAPTER_SRC/bin/mediaremote-adapter.pl" "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/MediaRemoteAdapterTestClient"

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

# 3.5. Рантайм Swift Concurrency для старых систем ----------------------------
#
# `async/await` появился в macOS 12, и при цели 11.0 компоновщик ищет
# `@rpath/libswift_Concurrency.dylib`. Пути, которые он прописывает, ведут
# ВНУТРЬ Xcode: на своей машине всё находится, на чужой — нет, и приложение
# падает на первом же `Task`. Библиотеку кладём в бандл, а чужие пути убираем,
# чтобы на машине с Xcode случайно не подхватился посторонний рантайм.
EXE="$APP/Contents/MacOS/NotchHub"
if otool -L "$EXE" | grep -q "@rpath/libswift_Concurrency.dylib"; then
    BACKDEPLOY="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-5.5/macosx/libswift_Concurrency.dylib"
    if [ ! -f "$BACKDEPLOY" ]; then
        echo "Нет библиотеки обратной совместимости: $BACKDEPLOY" >&2
        exit 1
    fi
    say "Кладу в бандл libswift_Concurrency.dylib (нужен на macOS 11)"
    cp "$BACKDEPLOY" "$APP/Contents/Frameworks/"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXE" 2>/dev/null || true
    # `|| true`: путей в Xcode может не оказаться вовсе, а пустой grep возвращает 1
    # и под `set -e` молча обрывает сборку на этом месте.
    STALE_RPATHS="$(otool -l "$EXE" \
        | awk '/LC_RPATH/{f=1} f&&/path /{print $2; f=0}' \
        | grep -F "/Xcode.app/" || true)"
    for stale in $STALE_RPATHS; do
        install_name_tool -delete_rpath "$stale" "$EXE" 2>/dev/null || true
    done
    codesign --force --sign - --timestamp=none "$APP/Contents/Frameworks/libswift_Concurrency.dylib" >/dev/null 2>&1
fi

# 3.9. Срезать отладочную карту линкера: в ней абсолютные пути сборки
# с именем пользователя (N_OSO/N_SO), и без strip они уезжают в раздаваемый
# образ. Предупреждение про подпись глушим — подписываем следующим шагом.
strip -S "$APP/Contents/MacOS/NotchHub" 2>/dev/null

# 4. Подпись ------------------------------------------------------------------
say "Подписываю ad-hoc"
codesign --force --sign - --timestamp=none "$APP/Contents/Frameworks/MediaRemoteAdapter.framework" >/dev/null 2>&1
codesign --force --sign - --timestamp=none "$APP/Contents/Resources/MediaRemoteAdapterTestClient" >/dev/null 2>&1
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1
codesign --verify --verbose=1 "$APP" 2>&1 | tail -2 || true

say "Готово: $APP (минимум macOS $MIN_MACOS)"
