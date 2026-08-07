#!/bin/bash
# Builds the release .app and installs it to /Applications.
# Installed this way there is no Gatekeeper friction (the app is built
# locally, so it carries no quarantine flag), and on first launch it
# registers itself to open at login.
set -euo pipefail

cd "$(dirname "$0")/.."

bash scripts/bundle.sh

APP="/Applications/ClaudeStats.app"

# Replace any running copy.
pkill -x ClaudeStatsApp 2>/dev/null || true
sleep 1
rm -rf "$APP"
cp -R .build/ClaudeStats.app "$APP"

open "$APP"

echo
echo "Installed $APP and launched it."
echo "It registers itself to open at login on first run — toggle that any"
echo "time via right-click on the menu bar item -> 'Launch at Login'."
