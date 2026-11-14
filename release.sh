#!/bin/bash
# DetectHugeFile — Copyright (C) 2026 Andrea Rossi
# Software libero: GNU General Public License v3 o successiva.
# Questo programma è distribuito SENZA ALCUNA GARANZIA. Vedi LICENSE e <https://www.gnu.org/licenses/>.
# Crea DMG firmato e notarizzato con il profilo PERSONALE (team ERFG38SR6A).
# Uso: ./release.sh [-v VERSIONE]      (default 1.0; build universale)
set -euo pipefail
cd "$(dirname "$0")"

VERSION="1.0"
while getopts "v:" o; do
  case "$o" in v) VERSION="$OPTARG" ;; *) echo "Uso: $0 [-v VERSIONE]"; exit 1 ;; esac
done

# Developer ID Application: Andrea Rossi (ERFG38SR6A) — hash per evitare ambiguità con Legolabs
export SIGN_IDENTITY="E51CA6DD779D76080BE6147D7D34596B4331E855"
TEAM_ID="ERFG38SR6A"
APPLE_ID="${APPLE_ID:-}"   # Apple ID di login del team; se vuoto viene chiesto
export NOTARY_PROFILE="dhf-notary"

security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY" \
  || { echo "Certificato Developer ID non trovato nel Keychain" >&2; exit 1; }

# Crea il profilo di notarizzazione se manca (chiede la password specifica per app)
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  [ -n "$APPLE_ID" ] || read -r -p "Apple ID: " APPLE_ID
  echo "▶ Profilo '$NOTARY_PROFILE' assente: lo creo (team $TEAM_ID, $APPLE_ID)."
  echo "  Password specifica per app: appleid.apple.com → Accesso e sicurezza"
  PW_ARGS=()
  [ -z "${NOTARY_PASSWORD:-}" ] || PW_ARGS=(--password "$NOTARY_PASSWORD")
  xcrun notarytool store-credentials "$NOTARY_PROFILE" --apple-id "$APPLE_ID" --team-id "$TEAM_ID" "${PW_ARGS[@]}"
fi

./make_dmg.sh -v "$VERSION" -u

DMG="dist/DetectHugeFile-$VERSION.dmg"
echo "▶ Verifica firma…"
codesign --verify --deep --strict --verbose=2 DetectHugeFile.app
codesign -dv DetectHugeFile.app 2>&1 | grep -E "Authority|TeamIdentifier"
spctl --assess --type open --context context:primary-signature -v "$DMG"
