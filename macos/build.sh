#!/usr/bin/env bash
# Builds "Megalith Widgets.app" from the Swift package.
#
#   ./build.sh            build into build/
#   ./build.sh --install  also copy it to /Applications and open it
#
# The app is ad-hoc signed, which is enough to run it locally. A copy
# downloaded from the internet needs its quarantine flag cleared once:
#   xattr -dr com.apple.quarantine "/Applications/Megalith Widgets.app"
set -euo pipefail

cd "$(dirname "$0")"
APP="build/Megalith Widgets.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/MegalithWidgets"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Fonts" "$APP/Contents/Resources/Icons"
cp "$BIN" "$APP/Contents/MacOS/MegalithWidgets"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp ../data/fonts/*.ttf "$APP/Contents/Resources/Fonts/"
cp Resources/Icons/*.pdf "$APP/Contents/Resources/Icons/"
iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"

echo "Built $APP"

if [[ ${1:-} == --install ]]; then
    osascript -e 'quit app "Megalith Widgets"' 2>/dev/null || true
    rm -rf "/Applications/Megalith Widgets.app"
    cp -R "$APP" /Applications/
    open "/Applications/Megalith Widgets.app"
    echo "Installed to /Applications"
fi
