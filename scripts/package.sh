#!/bin/zsh
# Упаковывает уже собранное приложение, проверяет подпись и архив.
set -eu
cd "${0:A:h}/.."
version=$(tr -d '\n' < VERSION)
app=.build/ShotQueue.app
codesign --verify --deep --strict "$app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" == "$version" ]]
for arch in arm64 x86_64; do
  xcrun lipo "$app/Contents/MacOS/ShotQueue" -verify_arch "$arch"
done
"$app/Contents/MacOS/ShotQueue" --self-test
mkdir -p .build/release
archive=".build/release/ShotQueue-$version-mac-universal.zip"
[[ ! -e "$archive" ]] || { echo "Архив уже существует: $archive" >&2; exit 1; }
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
unzip -tq "$archive"
(cd .build/release && shasum -a 256 "ShotQueue-$version-mac-universal.zip" > SHA256SUMS.txt)
echo "Готово: $archive"
