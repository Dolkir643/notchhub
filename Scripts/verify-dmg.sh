#!/bin/bash
# Проверить профиль, обе архитектуры и подписи приложения непосредственно из DMG.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DMG="${1:?Укажи DMG}"
EXPECTED="${2:?Укажи профиль legacy, notch или no-notch}"
case "$EXPECTED" in
    legacy) MINIMUM=11.0 ;;
    notch|no-notch) MINIMUM=14.0 ;;
    *) exit 1 ;;
esac
MOUNT="$(mktemp -d "$ROOT/build/verify.XXXXXX")"
cleanup() { hdiutil detach "$MOUNT" >/dev/null 2>&1 || true; rmdir "$MOUNT" 2>/dev/null || true; }
trap cleanup EXIT
hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$MOUNT" >/dev/null
APP="$MOUNT/NotchHub.app"
PLIST="$APP/Contents/Info.plist"
test "$(/usr/libexec/PlistBuddy -c 'Print :NotchHubVariant' "$PLIST")" = "$EXPECTED"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")" = "$MINIMUM"
for BIN in "$APP/Contents/MacOS/NotchHub" "$APP/Contents/Frameworks/MediaRemoteAdapter.framework/MediaRemoteAdapter"; do
    lipo "$BIN" -verify_arch arm64 x86_64
    for ARCH in arm64 x86_64; do
        ACTUAL="$(vtool -arch "$ARCH" -show-build "$BIN" | awk '/minos/{print $2}')"
        test "$ACTUAL" = "$MINIMUM"
    done
done
if [ "$EXPECTED" = legacy ]; then
    test -f "$APP/Contents/Frameworks/libswift_Concurrency.dylib"
fi
codesign --verify --deep --strict "$APP"
echo "Проверен $DMG: $EXPECTED, macOS $MINIMUM, arm64 + x86_64"
