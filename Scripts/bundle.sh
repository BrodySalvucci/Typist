#!/bin/bash
# Builds Typist.app into ./build from the SwiftPM package.
#
#   Scripts/bundle.sh            # release build, ad-hoc signed
#   SIGN_IDENTITY="Developer ID Application: …" Scripts/bundle.sh
#
# Accessibility permission is tied to the code signature. With ad-hoc signing
# macOS asks for permission again after every rebuild; sign with a stable
# identity to avoid that.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
APP="build/Typist.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
cp "$BIN/Typist" "$APP/Contents/MacOS/Typist"
cp -R "$BIN/llama.framework" "$APP/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Typist" 2>/dev/null || true

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Typist</string>
    <key>CFBundleIdentifier</key><string>org.typist.Typist</string>
    <key>CFBundleName</key><string>Typist</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

codesign --force --deep --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"
