#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release --product ClaudeStatsApp

APP_BUNDLE=".build/ClaudeStats.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

BIN_PATH="$(swift build -c release --product ClaudeStatsApp --show-bin-path)"
cp "$BIN_PATH/ClaudeStatsApp" "$MACOS_DIR/ClaudeStatsApp"
cp "Resources/Info.plist" "$CONTENTS/Info.plist"

codesign --force --deep -s - "$APP_BUNDLE"

echo "Bundled: $APP_BUNDLE"
