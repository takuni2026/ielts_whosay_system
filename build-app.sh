#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/outputs/IELTS Speaking Practice.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
  -module-cache-path "$ROOT/work/swift-module-cache" \
  -framework SwiftUI \
  -framework AppKit \
  -framework ScreenCaptureKit \
  -framework Vision \
  -framework Network \
  -framework CoreImage \
  -framework CoreGraphics \
  "$ROOT"/Sources/*.swift \
  -o "$APP/Contents/MacOS/IELTSPractice"

cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/phone.html" "$APP/Contents/Resources/phone.html"
codesign --force --deep --sign - --identifier com.macielts.practice \
  --requirements='=designated => identifier "com.macielts.practice"' "$APP"
echo "Built: $APP"
