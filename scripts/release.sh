#!/bin/bash
# Готовит выпуск в release/<версия>/: topbar-<версия>.zip (для автообновления), topbar-<версия>.dmg (для скачивания),
# appcast.xml (лента обновлений с подписью EdDSA) и release-notes.html. НИЧЕГО НЕ ПУБЛИКУЕТ — выкладка отдельным шагом.
#
# Переменные окружения:
#   TOPBAR_FEED_URL       куда будет выложен appcast.xml (адрес вшивается в приложение)          — обязательно
#   TOPBAR_DOWNLOAD_BASE  каталог, откуда скачиваются zip и dmg (без завершающего «/»)         — обязательно
#   TOPBAR_SERVER_URL     адрес службы аналитики и отзывов (необязательно; см. build-app.sh)
#   TOPBAR_VERSION, TOPBAR_BUILD — версия и номер сборки (по умолчанию VERSION и время сборки)
#   TOPBAR_ALLOW_HTTP=1   разрешить http (только проверка обновлений на своём Mac)
# Использование: scripts/release.sh [файл-с-описанием.html]
set -euo pipefail
cd "$(dirname "$0")/.."

: "${TOPBAR_FEED_URL:?задайте TOPBAR_FEED_URL — адрес appcast.xml}"
: "${TOPBAR_DOWNLOAD_BASE:?задайте TOPBAR_DOWNLOAD_BASE — откуда скачиваются файлы}"
VERSION="${TOPBAR_VERSION:-$(tr -d '[:space:]' < VERSION)}"
BUILD="${TOPBAR_BUILD:-$(date +%Y%m%d%H%M)}"
export TOPBAR_VERSION="$VERSION" TOPBAR_BUILD="$BUILD"
SIGN_DIR="$HOME/Library/Application Support/topbar-signing"
KEY="$SIGN_DIR/sparkle-ed25519.key"
[[ -f "$KEY" ]] || { echo "нет ключа обновлений — сначала scripts/setup-signing.sh"; exit 1; }
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    echo "ВНИМАНИЕ: в репозитории есть незакоммиченные изменения — выпуск соберётся из них."
fi

scripts/build-app.sh
OUT="release/$VERSION"
rm -rf "$OUT"; mkdir -p "$OUT"
ZIP="topbar-$VERSION.zip"; DMG="topbar-$VERSION.dmg"

# Архив для автообновления.
ditto -c -k --keepParent build/topbar.app "$OUT/$ZIP"

# Образ для скачивания: приложение, ссылка на «Программы» и памятка про первый запуск.
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
cp -R build/topbar.app "$STAGE/topbar.app"
ln -s /Applications "$STAGE/Applications"
cp docs/dmg-readme.txt "$STAGE/Откройте первым.txt"
hdiutil create -volname "topbar" -srcfolder "$STAGE" -ov -format UDZO "$OUT/$DMG" >/dev/null

# Описание версии и лента.
NOTES="${1:-}"
if [[ -z "$NOTES" ]]; then
    NOTES="$OUT/release-notes.html"
    printf '<p>Версия %s.</p>\n' "$VERSION" > "$NOTES"
else
    cp "$NOTES" "$OUT/release-notes.html"; NOTES="$OUT/release-notes.html"
fi
TOOL="$(mktemp -d)/release-tool"
swiftc -O scripts/tools/release-tool.swift -o "$TOOL"
"$TOOL" appcast "$KEY" "$OUT/$ZIP" "$TOPBAR_DOWNLOAD_BASE/$ZIP" "$VERSION" "$BUILD" "$NOTES" > "$OUT/appcast.xml"

# Проверки.
SIG="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$OUT/appcast.xml")"
"$TOOL" verify "$(tr -d '[:space:]' < scripts/sparkle-public-key.txt)" "$OUT/$ZIP" "$SIG" || { echo "подпись обновления не сходится"; exit 1; }
codesign --verify --strict build/topbar.app
echo
echo "Готово: $OUT/"
ls -la "$OUT" | tail -n +2
echo "Версия $VERSION (сборка $BUILD). Лента: $TOPBAR_FEED_URL"
