#!/bin/bash
set -e

# Lance tous les tests : Python (scripts, MCP, banc) puis Swift (app).
# Usage : ./scripts/test.sh [python|swift]

cd "$(dirname "$0")/.."

PYTHON="${VOXA_PYTHON:-$HOME/Library/Application Support/Voxa/.venv/bin/python}"

if [ "${1:-all}" != "swift" ]; then
    echo "🐍 Tests Python..."
    "$PYTHON" -m unittest discover -s tests/python
fi

if [ "${1:-all}" != "python" ]; then
    echo "🧪 Tests moteur natif (Packages/VoxaEngine)..."
    swift test --package-path Packages/VoxaEngine --quiet

    echo "🧪 Tests Swift..."
    xcodebuild test \
        -project TranscriptionApp/TranscriptionApp.xcodeproj \
        -scheme TranscriptionApp \
        -destination 'platform=macOS,arch=arm64' \
        -derivedDataPath ./build/DerivedData \
        -quiet
fi

echo "✅ Tests OK"
