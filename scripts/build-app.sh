#!/bin/sh
# Compila devTabs y arma build/devTabs.app firmada con un certificado estable,
# para que el permiso de Accesibilidad siga valiendo después de cada build.
# Para elegir otro certificado: DEVTABS_SIGN_ID="<nombre o hash>" scripts/build-app.sh
set -eu
cd "$(dirname "$0")/.."

swift build -c release --product devTabs

rm -rf "build/devTabs.app"
mkdir -p "build/devTabs.app/Contents/MacOS"
cp ".build/release/devTabs" "build/devTabs.app/Contents/MacOS/devTabs"
cp "Support/Info.plist" "build/devTabs.app/Contents/Info.plist"

SIGN_ID="${DEVTABS_SIGN_ID:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')}"
if [ -z "$SIGN_ID" ]; then
    echo "No encontré un certificado «Apple Development»; firmo ad hoc (el permiso de Accesibilidad se pide de nuevo en cada build)." >&2
    SIGN_ID="-"
fi
codesign --force --sign "$SIGN_ID" "build/devTabs.app"
echo "build/devTabs.app"
