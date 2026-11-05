#!/bin/bash
# Собирает build/topbar.app (приложение + мост хука + помощник плеера), подписывает ad-hoc.
# Использование: scripts/build-app.sh [--install]   (--install копирует в ~/Applications)
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product topbar
swift build -c release --product topbar-hook
BIN="$(swift build -c release --show-bin-path)"
APP="build/topbar.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/topbar" "$APP/Contents/MacOS/topbar"
cp "$BIN/topbar-hook" "$APP/Contents/MacOS/topbar-hook"
cp scripts/Info.plist "$APP/Contents/Info.plist"
# Помощник плеера (грузится внутрь системного perl, см. native/nowplaying.m). Копия в build/ нужна запускам из .build/debug.
clang -dynamiclib -fobjc-arc -fvisibility=default -mmacosx-version-min=14.0 -framework Foundation \
    native/nowplaying.m -o build/libtbnowplaying.dylib
cp build/libtbnowplaying.dylib "$APP/Contents/Resources/libtbnowplaying.dylib"
codesign --force --sign - --deep "$APP"
echo "собрано: $APP"

if [[ "${1:-}" == "--install" ]]; then
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/topbar.app"
    cp -R "$APP" "$HOME/Applications/topbar.app"
    echo "установлено: $HOME/Applications/topbar.app"
fi
