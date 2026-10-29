#!/bin/bash
# Crea dist/DetectHugeFile-<versione>.dmg pronto per una GitHub Release.
#
# Uso:
#   ./make_dmg.sh [-v VERSIONE] [-u]
#     -v VERSIONE   versione (default: 1.0; es. 1.2.0)
#     -u            binario universale (arm64 + x86_64)
#
# Variabili opzionali (distribuzione "pulita", senza avviso di Gatekeeper):
#   SIGN_IDENTITY   es. "Developer ID Application: Nome Cognome (TEAMID)"
#   NOTARY_PROFILE  profilo creato con `xcrun notarytool store-credentials`
#
# Senza SIGN_IDENTITY l'app è firmata "ad-hoc": funziona, ma chi scarica dovrà
# autorizzarla la prima volta (vedi note stampate alla fine).
set -euo pipefail
cd "$(dirname "$0")"

VERSION="1.0"
UNIVERSAL=0
while getopts "v:uh" o; do
  case "$o" in
    v) VERSION="$OPTARG" ;;
    u) UNIVERSAL=1 ;;
    *) sed -n '2,15p' "$0"; exit 0 ;;
  esac
done

NAME="DetectHugeFile"
DIST="dist"
DMG="$DIST/$NAME-$VERSION.dmg"
STAGE="$(mktemp -d)/$NAME"
trap 'rm -rf "$(dirname "$STAGE")"' EXIT

echo "▶ Compilazione app $VERSION$([ $UNIVERSAL = 1 ] && echo ' (universale)')…"
if [ $UNIVERSAL = 1 ]; then ARCHS="arm64 x86_64" VERSION="$VERSION" ./build_app.sh >/dev/null
else VERSION="$VERSION" ./build_app.sh >/dev/null; fi
APP="$NAME.app"
[ -d "$APP" ] || { echo "App non trovata" >&2; exit 1; }

if [ -n "${NOTARY_PROFILE:-}" ]; then
  [ -n "${SIGN_IDENTITY:-}" ] || { echo "NOTARY_PROFILE richiede SIGN_IDENTITY" >&2; exit 1; }
  echo "▶ Notarizzazione app…"
  ditto -c -k --keepParent "$APP" "$STAGE.zip"
  xcrun notarytool submit "$STAGE.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$STAGE.zip"
fi

echo "▶ Creazione DMG…"
mkdir -p "$STAGE" "$DIST"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$NAME $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null

if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "▶ Notarizzazione DMG…"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  fi
fi

echo "▶ Verifica…"
hdiutil verify "$DMG" >/dev/null
( cd "$DIST" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" )

echo
echo "✔ $DMG  ($(du -h "$DMG" | cut -f1))"
echo "  SHA-256: $(cut -d' ' -f1 "$DMG.sha256")"
echo "  Architetture: $(lipo -archs "$APP/Contents/MacOS/$NAME")"
if [ -z "${SIGN_IDENTITY:-}" ]; then
  cat <<'NOTE'

Nota: firma ad-hoc. Chi scarica il DMG da internet vedrà l'avviso di Gatekeeper.
Per aprirla: clic destro sull'app → Apri, oppure
  xattr -dr com.apple.quarantine /Applications/DetectHugeFile.app
NOTE
fi
echo
echo "Release su GitHub (dopo il push del tag):"
echo "  gh release create v$VERSION $DMG $DMG.sha256 --title \"$NAME $VERSION\" --generate-notes"
