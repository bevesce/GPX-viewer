#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "Building Gpxex (Release)..."
xcodebuild \
    -project "$PROJECT_DIR/Gpxex.xcodeproj" \
    -scheme Gpxex \
    -configuration Release \
    -destination 'platform=macOS' \
    build

APP=$(find ~/Library/Developer/Xcode/DerivedData/Gpxex-*/Build/Products/Release/Gpxex.app -maxdepth 0 2>/dev/null | head -1)

if [ -z "$APP" ]; then
    echo "Error: could not find built Gpxex.app" >&2
    exit 1
fi

echo "Installing to /Applications..."
rm -rf /Applications/Gpxex.app
cp -r "$APP" /Applications/Gpxex.app

echo "Done. Gpxex.app installed to /Applications."
