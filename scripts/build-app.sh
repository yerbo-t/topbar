#!/bin/bash
# Собирает build/topbar.app: приложение, мост хука, помощник плеера, Sparkle (автообновление), значок. Подписывает.
# Использование: scripts/build-app.sh [--install]    (--install копирует в ~/Applications)
# Переменные окружения:
#   TOPBAR_VERSION       версия (по умолчанию — из файла VERSION)
#   TOPBAR_BUILD         номер сборки (по умолчанию — число коммитов)
#   TOPBAR_FEED_URL      адрес ленты обновлений (appcast.xml); без него обновления в сборке выключены
#   TOPBAR_PING_URL      адрес, куда (с согласия человека) уходит запись «пользуюсь topbar»; без него ничего не спрашивается и не шлётся
#   TOPBAR_ALLOW_HTTP=1  разрешить http для ленты (только для локальной проверки обновлений)
# Подпись: сертификат «topbar release» из scripts/setup-signing.sh, если он доверенный; иначе ad-hoc (разрешения слетают при
# каждой сборке — для разработки терпимо, для выпуска нет).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${TOPBAR_VERSION:-$(tr -d '[:space:]' < VERSION)}"
BUILD="${TOPBAR_BUILD:-$(git rev-list --count HEAD)}"
FEED_URL="${TOPBAR_FEED_URL:-}"
SIGN_DIR="$HOME/Library/Application Support/topbar-signing"
KEYCHAIN="$SIGN_DIR/topbar-signing.keychain-db"
APP="build/topbar.app"

swift build -c release --product topbar
swift build -c release --product topbar-hook
BIN="$(swift build -c release --show-bin-path)"
SPARKLE="$(find .build/artifacts -maxdepth 6 -type d -name Sparkle.framework -path '*macos-arm64_x86_64*' | head -1)"
[[ -d "$SPARKLE" ]] || { echo "не найден Sparkle.framework (swift package resolve)"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/topbar" "$APP/Contents/MacOS/topbar"
cp "$BIN/topbar-hook" "$APP/Contents/MacOS/topbar-hook"
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"

# Info.plist: версия, лента обновлений, открытый ключ подписи обновлений.
PUBLIC_KEY="$(tr -d '[:space:]' < scripts/sparkle-public-key.txt)"
KEYS="    <key>SUPublicEDKey</key><string>$PUBLIC_KEY</string>"
if [[ -n "$FEED_URL" ]]; then
    KEYS="$KEYS
    <key>SUFeedURL</key><string>$FEED_URL</string>"
fi
if [[ -n "${TOPBAR_PING_URL:-}" ]]; then
    KEYS="$KEYS
    <key>TopbarPingURL</key><string>${TOPBAR_PING_URL}</string>"
fi
if [[ "${TOPBAR_ALLOW_HTTP:-}" == "1" ]]; then
    KEYS="$KEYS
    <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/><key>NSAllowsArbitraryLoads</key><true/></dict>"
fi
python3 - "$VERSION" "$BUILD" "$KEYS" <<'PY'
import sys
version, build, keys = sys.argv[1:4]
text = open("scripts/Info.plist", encoding="utf-8").read()
text = text.replace("@VERSION@", version).replace("@BUILD@", build).replace("@SPARKLE_KEYS@", keys)
open("build/topbar.app/Contents/Info.plist", "w", encoding="utf-8").write(text)
PY

# Значок.
if [[ -f scripts/AppIcon.icns ]]; then cp scripts/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi

# Помощник плеера (грузится внутрь системного perl, см. native/nowplaying.m). Копия в build/ нужна запускам из .build/debug.
clang -dynamiclib -fobjc-arc -fvisibility=default -mmacosx-version-min=14.0 -framework Foundation \
    native/nowplaying.m -o build/libtbnowplaying.dylib
cp build/libtbnowplaying.dylib "$APP/Contents/Resources/libtbnowplaying.dylib"

# Подпись: изнутри наружу, без --deep.
IDENTITY="-"
KC_ARGS=()
if [[ -f "$KEYCHAIN" ]] && security unlock-keychain -p "$(cat "$SIGN_DIR/keychain-password")" "$KEYCHAIN" 2>/dev/null \
   && security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "topbar release"; then
    IDENTITY="topbar release"
    KC_ARGS=(--keychain "$KEYCHAIN")
else
    echo "ВНИМАНИЕ: сертификат «topbar release» не доверенный — подписываю ad-hoc (после установки разрешения придётся включать заново)."
fi
sign() { codesign --force --sign "$IDENTITY" ${KC_ARGS[@]+"${KC_ARGS[@]}"} "$@"; }
FW="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for part in "$FW/XPCServices/Installer.xpc" "$FW/XPCServices/Downloader.xpc" "$FW/Autoupdate" "$FW/Updater.app"; do
    [[ -e "$part" ]] && sign "$part"
done
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign "$APP/Contents/Resources/libtbnowplaying.dylib"
sign "$APP/Contents/MacOS/topbar-hook"
sign "$APP"
codesign --verify --strict "$APP" && echo "подпись проверена: $(codesign -dr - "$APP" 2>&1 | sed -n 's/^# designated => //p;s/^designated => //p' | cut -c1-110)"
echo "собрано: $APP  версия $VERSION ($BUILD), подпись «${IDENTITY}»${FEED_URL:+, лента ${FEED_URL}}"

if [[ "${1:-}" == "--install" ]]; then
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/topbar.app"
    cp -R "$APP" "$HOME/Applications/topbar.app"
    echo "установлено: $HOME/Applications/topbar.app"
fi
