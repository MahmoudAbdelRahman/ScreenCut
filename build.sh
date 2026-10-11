#!/bin/zsh
set -e
cd "$(dirname "$0")"

swift build -c release --triple arm64-apple-macosx15.0
swift build -c release --triple x86_64-apple-macosx15.0

APP=build/Mahmoud.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create -output "$APP/Contents/MacOS/Mahmoud" \
    .build/arm64-apple-macosx/release/ScreenCut \
    .build/x86_64-apple-macosx/release/ScreenCut

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Mahmoud</string>
    <key>CFBundleDisplayName</key><string>Mahmoud</string>
    <key>CFBundleIdentifier</key><string>local.mahmoud.Mahmoud</string>
    <key>CFBundleExecutable</key><string>Mahmoud</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSMicrophoneUsageDescription</key><string>Mahmoud records your microphone when you turn it on in the recording options.</string>
    <key>NSScreenCaptureUsageDescription</key><string>Mahmoud records the screen, window or app you choose.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
rm -f build/Mahmoud.zip
ditto -c -k --keepParent "$APP" build/Mahmoud.zip
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Mahmoud")) and build/Mahmoud.zip"
