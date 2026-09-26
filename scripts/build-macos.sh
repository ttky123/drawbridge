#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
APP="$ROOT/dist/Drawbridge.app"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
mkdir -p "$ROOT/.build/module-cache"
cp "$ROOT/macos/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/server.js" "$ROOT/package.json" "$ROOT/package-lock.json" "$APP/Contents/Resources/"
rm -rf "$APP/Contents/Resources/node_modules"
cp -R "$ROOT/node_modules" "$APP/Contents/Resources/node_modules"
swiftc "$ROOT/macos/Sources/main.swift" -target arm64-apple-macosx15.0 -module-cache-path "$ROOT/.build/module-cache" -framework AppKit -framework ScreenCaptureKit -framework UniformTypeIdentifiers -o "$APP/Contents/MacOS/Drawbridge"
codesign --force --sign - --requirements '=designated => identifier "com.drawbridge.mac"' "$APP"
echo "$APP"
