#!/bin/bash
# Один раз на Mac, где собираются выпуски: создаёт
#   1) самоподписанный сертификат подписи кода в отдельной связке ключей (логин-связка не трогается);
#   2) ключ EdDSA для подписи обновлений Sparkle.
# Всё лежит в ~/Library/Application Support/topbar-signing (права 0700). ЭТУ ПАПКУ НУЖНО СОХРАНИТЬ В НАДЁЖНОМ МЕСТЕ:
# потеряете ключ EdDSA — приложения у друзей больше не смогут принять обновление; потеряете сертификат — у них слетят
# разрешения («Универсальный доступ», «Автоматизация») после следующего обновления.
set -euo pipefail
cd "$(dirname "$0")/.."

DIR="$HOME/Library/Application Support/topbar-signing"
KEYCHAIN="$DIR/topbar-signing.keychain-db"
NAME="topbar release"
mkdir -p "$DIR"; chmod 700 "$DIR"

if [[ ! -f "$KEYCHAIN" ]]; then
    PW="$(openssl rand -hex 16)"
    printf '%s' "$PW" > "$DIR/keychain-password"; chmod 600 "$DIR/keychain-password"
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
    security create-keychain -p "$PW" "$KEYCHAIN"
    security set-keychain-settings "$KEYCHAIN"                      # без автоблокировки
    security unlock-keychain -p "$PW" "$KEYCHAIN"
    # Ключ и сертификат импортируются отдельно (PKCS12 от LibreSSL macOS не принимает); связка сама соберёт из них идентичность.
    security import "$TMP/key.pem" -k "$KEYCHAIN" -T /usr/bin/codesign >/dev/null
    security import "$TMP/cert.pem" -k "$KEYCHAIN" >/dev/null
    security set-key-partition-list -S apple-tool:,apple: -s -k "$PW" "$KEYCHAIN" >/dev/null
    cp "$TMP/cert.pem" "$DIR/topbar-release-cert.pem"
    echo "создан сертификат подписи «${NAME}»"
fi

if [[ ! -f "$DIR/sparkle-ed25519.key" ]]; then
    TOOL="$(mktemp -d)/release-tool"
    swiftc -O scripts/tools/release-tool.swift -o "$TOOL"
    PUB="$("$TOOL" keygen "$DIR/sparkle-ed25519.key")"
    echo "создан ключ EdDSA для обновлений"
fi

# Открытая часть ключа обновлений — не секрет, она вшивается в приложение и лежит в репозитории.
TOOL="$(mktemp -d)/release-tool"
swiftc -O scripts/tools/release-tool.swift -o "$TOOL"
"$TOOL" public "$DIR/sparkle-ed25519.key" > scripts/sparkle-public-key.txt
echo "открытый ключ обновлений: $(cat scripts/sparkle-public-key.txt)"
echo "папка с секретами: $DIR  (СОХРАНИТЕ КОПИЮ)"
