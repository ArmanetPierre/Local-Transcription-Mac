#!/bin/bash
set -e

# Build, sign, notarize, and package Voxa.dmg
# Usage: ./scripts/build-dmg.sh
#
# First-time setup:
#   xcrun notarytool store-credentials "Voxa-Notarize" \
#     --apple-id "YOUR_APPLE_ID" --team-id "C3A57SQ939" --password "APP_SPECIFIC_PASSWORD"

cd "$(dirname "$0")/.."

SIGN_IDENTITY="Developer ID Application: Pierre Armanet (C3A57SQ939)"
NOTARIZE_PROFILE="Voxa-Notarize"
APP_PATH="./build/Build/Products/Release/Voxa.app"

# 1. Build
echo "🔨 Building Voxa (Release)..."
xcodebuild -project TranscriptionApp/TranscriptionApp.xcodeproj \
    -scheme TranscriptionApp \
    -configuration Release \
    -derivedDataPath ./build \
    -arch arm64 \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    CODE_SIGN_STYLE="Manual" \
    OTHER_CODE_SIGN_FLAGS="--options=runtime" \
    ONLY_ACTIVE_ARCH=NO \
    -quiet

if [ ! -d "$APP_PATH" ]; then
    echo "❌ Build failed: Voxa.app not found"
    exit 1
fi

# 2. Sign (deep sign all nested binaries)
echo "🔏 Signing Voxa.app..."
codesign --deep --force --options runtime \
    --sign "$SIGN_IDENTITY" \
    --entitlements TranscriptionApp/TranscriptionApp/Resources/TranscriptionApp.entitlements \
    "$APP_PATH"

codesign --verify --deep --strict "$APP_PATH"
echo "   Signature verified"

# 3. Create DMG
echo "📦 Creating DMG..."
rm -rf dmg_staging
mkdir -p dmg_staging
cp -R "$APP_PATH" dmg_staging/
ln -s /Applications dmg_staging/Applications

rm -f Voxa.dmg
hdiutil create -volname "Voxa" -srcfolder dmg_staging -ov -format UDZO "Voxa.dmg"
rm -rf dmg_staging

# 4. Sign DMG
codesign --force --sign "$SIGN_IDENTITY" "Voxa.dmg"

# 5. Notarize
echo "📤 Submitting for notarization..."
xcrun notarytool submit "Voxa.dmg" \
    --keychain-profile "$NOTARIZE_PROFILE" \
    --wait

# 6. Staple
echo "📎 Stapling notarization ticket..."
xcrun stapler staple "Voxa.dmg"

DMG_SIZE=$(du -h Voxa.dmg | cut -f1)
echo ""
echo "✅ Voxa.dmg created, signed, and notarized ($DMG_SIZE)"
echo ""
echo "Installation:"
echo "  1. Open Voxa.dmg"
echo "  2. Drag Voxa to Applications"
echo "  3. Launch Voxa and follow the setup wizard"
