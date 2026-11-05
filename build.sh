#!/bin/zsh
set -eu
ROOT="${0:A:h}"
DEST="${1:-$ROOT/build/表情匣.app}"
mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources"
xcrun swiftc -swift-version 5 -target arm64-apple-macos13.0 -O -whole-module-optimization "$ROOT/Sources/Main.swift" -o "$DEST/Contents/MacOS/StickerBox" -framework AppKit -framework ImageIO -framework UniformTypeIdentifiers -framework CryptoKit
cp "$ROOT"/Resources/* "$DEST/Contents/Resources/"
cp "$ROOT/Info.plist" "$DEST/Contents/Info.plist"
strip -x "$DEST/Contents/MacOS/StickerBox"
codesign --force --sign - "$DEST"
