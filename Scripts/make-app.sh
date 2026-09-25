#!/bin/bash
# Builds NoteTaker and assembles a runnable .app bundle at build/NoteTaker.app
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/NoteTaker.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/NoteTaker "$APP/Contents/MacOS/NoteTaker"
cp App/Info.plist "$APP/Contents/Info.plist"
cp App/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature — required for the microphone / system-audio permission prompts
codesign --force --sign - "$APP"

echo ""
echo "Built $APP"
echo "Launch with:  open $APP"
