#!/bin/bash
# Выкладывает подготовленный выпуск (scripts/release.sh) в релизы GitHub: архив для обновления, образ для скачивания и лента.
# ВЫКЛАДКА НАРУЖУ: запускать только по решению владельца, с явным флагом --yes.
# Использование: scripts/publish.sh [--yes]      (версия — из файла VERSION или TOPBAR_VERSION)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${TOPBAR_VERSION:-$(tr -d '[:space:]' < VERSION)}"
REPO="${TOPBAR_GITHUB_REPO:-yerbo-t/topbar}"
OUT="release/$VERSION"
[[ -f "$OUT/appcast.xml" && -f "$OUT/topbar-$VERSION.zip" && -f "$OUT/topbar.dmg" ]] || { echo "нет готового выпуска $OUT — сначала scripts/release.sh"; exit 1; }
grep -q "releases/download/v$VERSION/" "$OUT/appcast.xml" || { echo "в ленте адрес архива не для релиза v$VERSION на GitHub — собирайте без TOPBAR_DOWNLOAD_BASE"; exit 1; }
if [[ "${1:-}" != "--yes" ]]; then
    echo "Будет опубликован релиз v$VERSION в $REPO: $(ls "$OUT" | tr '\n' ' ')"
    echo "Повторите с флагом --yes, если это решено."
    exit 2
fi
NOTES="$OUT/notes.md"
sed -e 's/<[^>]*>//g' "$OUT/release-notes.html" > "$NOTES"
gh release create "v$VERSION" "$OUT/topbar-$VERSION.zip" "$OUT/topbar.dmg" "$OUT/appcast.xml" \
    --repo "$REPO" --title "topbar $VERSION" --notes-file "$NOTES" --latest
echo "опубликовано: https://github.com/$REPO/releases/tag/v$VERSION"
