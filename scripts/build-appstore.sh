#!/bin/bash
set -e

# Archive la version Mac App Store de Voxa et l'envoie a App Store Connect.
# Usage : ./scripts/build-appstore.sh            (archive + envoi)
#         ./scripts/build-appstore.sh --archive  (archive seulement, a envoyer depuis Xcode > Organizer)
#
# Prerequis (une fois) : compte developpeur ajoute dans Xcode > Reglages > Comptes,
# et fiche de l'app creee dans App Store Connect avec l'identifiant com.pierre.voxa.appstore.
# Avant chaque envoi : augmenter CURRENT_PROJECT_VERSION (et MARKETING_VERSION pour
# une nouvelle version) de la cible VoxaAppStore dans TranscriptionApp/project.yml.

cd "$(dirname "$0")/.."

ARCHIVE="./build/AppStore/Voxa.xcarchive"
EXPORT_DIR="./build/AppStore/export"

echo "🧪 Tests..."
./scripts/test.sh

echo "🛠  Generation du projet..."
(cd TranscriptionApp && xcodegen generate -q)

echo "📦 Archive (VoxaAppStore, Release)..."
rm -rf "$ARCHIVE"
xcodebuild archive \
    -project TranscriptionApp/TranscriptionApp.xcodeproj \
    -scheme VoxaAppStore \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates \
    -quiet

VERSION=$(/usr/libexec/PlistBuddy -c "Print ApplicationProperties:CFBundleShortVersionString" "$ARCHIVE/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print ApplicationProperties:CFBundleVersion" "$ARCHIVE/Info.plist")
echo "   Version $VERSION (build $BUILD)"

if [ "$1" == "--archive" ]; then
    echo "✅ Archive prete : $ARCHIVE"
    echo "   Ouvrir avec : open \"$ARCHIVE\"  puis Distribute App > App Store Connect"
    exit 0
fi

echo "📤 Envoi a App Store Connect..."
rm -rf "$EXPORT_DIR"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist scripts/ExportOptions-AppStore.plist \
    -exportPath "$EXPORT_DIR" \
    -allowProvisioningUpdates

echo "✅ Build $VERSION ($BUILD) envoye. Il apparait dans App Store Connect > TestFlight apres le traitement (10-30 min)."
