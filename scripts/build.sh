#!/bin/zsh
# Собирает локальное Mac-приложение ShotQueue из Sources/.
# Запуск: ./scripts/build.sh из корня зоны ShotQueue.
set -eu
cd "${0:A:h}/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
mkdir -p .build/ShotQueue.app/Contents/MacOS .build/ShotQueue.app/Contents/Resources
cat > .build/ShotQueue.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>life.azat.shotqueue</string>
<key>CFBundleName</key><string>ShotQueue</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleExecutable</key><string>ShotQueue</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
xcrun swiftc -parse-as-library -swift-version 5 -O -framework AppKit -framework ScreenCaptureKit -framework Carbon \
  Sources/ShotQueue.swift -o .build/ShotQueue.app/Contents/MacOS/ShotQueue
.build/ShotQueue.app/Contents/MacOS/ShotQueue --export-icon .build/AppIcon.iconset
iconutil -c icns .build/AppIcon.iconset -o .build/ShotQueue.app/Contents/Resources/AppIcon.icns
signing_identity=$(security find-identity -v -p codesigning | awk '/"Apple Development:/ {print $2; exit}')
if [[ -z "$signing_identity" ]]; then
  echo "Не найден сертификат Apple Development для подписи ShotQueue" >&2
  exit 1
fi
codesign --force --timestamp=none --sign "$signing_identity" .build/ShotQueue.app
echo "Собрано: .build/ShotQueue.app"
