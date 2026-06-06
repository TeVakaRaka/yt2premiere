#!/bin/bash
# Собирает нативное приложение yt2premiere.app из YT2Premiere.swift.
# Требуется Xcode Command Line Tools (swiftc). Запуск: bash build.sh
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/../yt2premiere.app"

echo "Собираю $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>yt2premiere</string>
    <key>CFBundleDisplayName</key><string>yt2premiere</string>
    <key>CFBundleIdentifier</key><string>com.tevaka.yt2premiere</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>yt2premiere</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>11.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
</dict>
</plist>
PLIST

swiftc -O -o "$APP/Contents/MacOS/yt2premiere" "$DIR/YT2Premiere.swift"
echo "✅ Готово: $APP"
echo "Установить: cp -R \"$APP\" /Applications/"
