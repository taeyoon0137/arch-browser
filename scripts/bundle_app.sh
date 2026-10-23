#!/bin/sh
# Assemble `build/Arch.app` using Swift Package Manager (SwiftPM) build products and the Chromium Embedded Framework (CEF) distribution in `Frameworks/cef`.
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
  # `$1` is the output path. `$2` is the executable name. `$3` is the bundle identifier. `$4` is the user interface element flag (0/1). `$5` holds extra keys for the main app.
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
${5:-}
</dict>
</plist>
PLIST
}

# The main app registers for web links so the system can offer it as the default browser. The usage descriptions are required before the system asks for the camera, microphone, or location on a page's behalf.
APP_KEYS='	<key>NSCameraUsageDescription</key><string>Web pages can use the camera after you allow them.</string>
	<key>NSMicrophoneUsageDescription</key><string>Web pages can use the microphone after you allow them.</string>
	<key>NSLocationUsageDescription</key><string>Web pages can use your location after you allow them.</string>
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLName</key><string>Web Address</string>
			<key>CFBundleURLSchemes</key><array><string>http</string><string>https</string></array>
			<key>CFBundleTypeRole</key><string>Viewer</string>
		</dict>
	</array>'

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN/Arch" "$APP/Contents/MacOS/Arch"
write_plist "$APP/Contents/Info.plist" "Arch" "local.arch.browser" 0 "$APP_KEYS"
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

# A stable signing identity keeps the Keychain items Chromium creates readable across builds. Set `ARCH_SIGN_IDENTITY` to override the automatic choice. Otherwise, use the first Apple Development identity on this Mac, or ad-hoc signing if none exists.
IDENTITY="${ARCH_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -n 1)}"
codesign --force --deep --sign "${IDENTITY:--}" "$APP" >/dev/null 2>&1 || echo "signing with '${IDENTITY:-ad-hoc}' failed; the app may still run locally" >&2
echo "$APP"
