#!/bin/bash
set -e

# Build, sign, notarize, and package Voxa.dmg + Sparkle update zip
# Usage: ./scripts/build-dmg.sh
#
# First-time setup:
#   xcrun notarytool store-credentials "Voxa-Notarize" \
#     --apple-id "YOUR_APPLE_ID" --team-id "C3A57SQ939" --password "APP_SPECIFIC_PASSWORD"

cd "$(dirname "$0")/.."

SIGN_IDENTITY="Developer ID Application: Pierre Armanet (C3A57SQ939)"
NOTARIZE_PROFILE="Voxa-Notarize"
APP_PATH="./build/Build/Products/Release/Voxa.app"
SPARKLE_SIGN="./build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
GITHUB_REPO="ArmanetPierre/Local-Transcription-Mac"

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

# Extract version from built app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP_PATH/Contents/Info.plist")
echo "   Version: $VERSION (build $BUILD)"

# 2. Sign (deep sign all nested binaries)
echo "🔏 Signing Voxa.app..."
codesign --deep --force --options runtime \
    --sign "$SIGN_IDENTITY" \
    --entitlements TranscriptionApp/TranscriptionApp/Resources/TranscriptionApp.entitlements \
    "$APP_PATH"

codesign --verify --deep --strict "$APP_PATH"
echo "   Signature verified"

# 3. Create DMG (for first-time installs)
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

# 5. Notarize DMG
echo "📤 Notarizing DMG..."
xcrun notarytool submit "Voxa.dmg" \
    --keychain-profile "$NOTARIZE_PROFILE" \
    --wait

echo "📎 Stapling DMG..."
xcrun stapler staple "Voxa.dmg"

# 6. Create zip for Sparkle updates
echo "📦 Creating Voxa.zip for Sparkle updates..."
rm -f Voxa.zip
cd ./build/Build/Products/Release
zip -ryq ../../../../Voxa.zip Voxa.app
cd ../../../../

# 7. Sign zip with Sparkle EdDSA
echo "🔐 Signing Voxa.zip with EdDSA..."
SIGN_OUTPUT=$("$SPARKLE_SIGN" Voxa.zip)
echo "   $SIGN_OUTPUT"

# Parse signature and length from sign_update output
ED_SIGNATURE=$(echo "$SIGN_OUTPUT" | grep -o 'sparkle:edSignature="[^"]*"' | sed 's/sparkle:edSignature="//;s/"//')
FILE_LENGTH=$(echo "$SIGN_OUTPUT" | grep -o 'length="[^"]*"' | sed 's/length="//;s/"//')

if [ -z "$ED_SIGNATURE" ]; then
    echo "❌ Failed to get EdDSA signature"
    exit 1
fi

# 8. Generate appcast.xml
echo "📝 Generating appcast.xml..."
PUB_DATE=$(date -u +"%a, %d %b %Y %H:%M:%S +0000")
DOWNLOAD_URL="https://github.com/$GITHUB_REPO/releases/download/v$VERSION/Voxa.zip"

mkdir -p docs
cat > docs/appcast.xml << EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Voxa</title>
    <link>https://armanetpierre.github.io/Local-Transcription-Mac/appcast.xml</link>
    <description>Voxa Updates</description>
    <language>en</language>
    <item>
      <title>Voxa $VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <enclosure url="$DOWNLOAD_URL"
                 sparkle:version="$BUILD"
                 sparkle:shortVersionString="$VERSION"
                 length="$FILE_LENGTH"
                 type="application/octet-stream"
                 sparkle:edSignature="$ED_SIGNATURE"/>
    </item>
  </channel>
</rss>
EOF

DMG_SIZE=$(du -h Voxa.dmg | cut -f1)
ZIP_SIZE=$(du -h Voxa.zip | cut -f1)
echo ""
echo "✅ Build complete!"
echo "   Voxa.dmg: $DMG_SIZE (signed + notarized, for first install)"
echo "   Voxa.zip: $ZIP_SIZE (signed with EdDSA, for Sparkle updates)"
echo "   docs/appcast.xml: updated for v$VERSION"
echo ""
echo "Next steps:"
echo "  1. git add docs/appcast.xml && git commit && git push"
echo "  2. gh release create v$VERSION Voxa.dmg Voxa.zip --title \"Voxa v$VERSION\""
