#!/bin/zsh
set -euo pipefail

root=${0:A:h}
cd "$root"
mkdir -p dist/LidKeep.app/Contents/MacOS dist/LidKeep.app/Contents/Resources

for architecture in arm64 x86_64; do
  swiftc -O -parse-as-library -target "${architecture}-apple-macos15.0" \
    -framework AppKit -framework ServiceManagement \
    Sources/LidKeep.swift -o "dist/LidKeep-${architecture}"
done
lipo -create dist/LidKeep-arm64 dist/LidKeep-x86_64 -output dist/LidKeep.app/Contents/MacOS/LidKeep
rm dist/LidKeep-arm64 dist/LidKeep-x86_64

swift Tools/MakeIcon.swift "$root/dist/LidKeep.app/Contents/Resources/LidKeep.icns"
cp Info.plist dist/LidKeep.app/Contents/Info.plist
codesign --force --deep --sign - dist/LidKeep.app
codesign --verify --deep --strict --verbose=2 dist/LidKeep.app

cd dist
rm -f LidKeep-macOS15-universal.zip
ditto --norsrc -c -k --keepParent LidKeep.app LidKeep-macOS15-universal.zip
shasum -a 256 LidKeep-macOS15-universal.zip
