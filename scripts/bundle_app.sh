#!/bin/sh
# Assembles `build/Arch.app` from Swift Package Manager (SwiftPM) build products and the Chromium Embedded Framework (CEF) distribution in `Frameworks/cef`.
# Usage: scripts/bundle_app.sh [debug|release]
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
BIN="$ROOT/.build/$CONFIG"
CEF="$ROOT/Frameworks/cef/Release/Chromium Embedded Framework.framework"
APP="$ROOT/build/Arch.app"
VERSION="0.1.0"

[ -x "$BIN/Arch" ] || { echo "missing $BIN/Arch; run swift build -c $CONFIG first" >&2; exit 1; }
[ -x "$BIN/ArchHelper" ] || { echo "missing $BIN/ArchHelper" >&2; exit 1; }
[ -d "$CEF" ] || { echo "missing CEF framework at $CEF" >&2; exit 1; }

write_plist() {
  # `$1`: path; `$2`: executable name; `$3`: bundle identifier; `$4`: user interface element flag (0/1).
  cat > "$1" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>$2</string>
	<key>CFBundleIdentifier</key><string>$3</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>$2</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$VERSION</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>LSEnvironment</key><dict><key>MallocNanoZone</key><string>0</string></dict>
	<key>LSUIElement</key><string>$4</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST
}

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN/Arch" "$APP/Contents/MacOS/Arch"
write_plist "$APP/Contents/Info.plist" "Arch" "local.arch.browser" 0
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp -R "$CEF" "$APP/Contents/Frameworks/"

for suffix in "" " (GPU)" " (Renderer)" " (Plugin)" " (Alerts)"; do
  name="Arch Helper$suffix"
  helper="$APP/Contents/Frameworks/$name.app"
  mkdir -p "$helper/Contents/MacOS"
  cp "$BIN/ArchHelper" "$helper/Contents/MacOS/$name"
  idsuffix="$(printf '%s' "$suffix" | tr -d ' ()' | tr 'A-Z' 'a-z')"
  write_plist "$helper/Contents/Info.plist" "$name" "local.arch.browser.helper${idsuffix:+.$idsuffix}" 1
  printf 'APPL????' > "$helper/Contents/PkgInfo"
done

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "ad-hoc signing failed; the app may still run locally" >&2
echo "$APP"
