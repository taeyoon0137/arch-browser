#!/bin/sh
# Assemble `build/Arch.app` using Swift Package Manager (SwiftPM) build products and the Chromium Embedded Framework (CEF) distribution in `Frameworks/cef`.
# Usage: scripts/bundle_app.sh [debug|release]
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
BIN="$ROOT/.build/$CONFIG"
CEF="$ROOT/Frameworks/cef/Release/Chromium Embedded Framework.framework"
ICON_SOURCE="$ROOT/resources/assets/sym_arch.png"
SDEF="$ROOT/Packages/ARCHApp/Sources/Arch/Arch.sdef"
APP="$ROOT/build/Arch.app"
VERSION="0.1.0"
MIN_MACOS="14.0"

[ -x "$BIN/Arch" ] || { echo "missing $BIN/Arch; run swift build -c $CONFIG first" >&2; exit 1; }
[ -x "$BIN/ArchHelper" ] || { echo "missing $BIN/ArchHelper" >&2; exit 1; }
[ -d "$CEF" ] || { echo "missing CEF framework at $CEF" >&2; exit 1; }
[ -f "$ICON_SOURCE" ] || { echo "missing app icon source at $ICON_SOURCE" >&2; exit 1; }
[ -f "$SDEF" ] || { echo "missing scripting definition at $SDEF" >&2; exit 1; }

write_plist() {
  # Arguments: `$1` is the output path, `$2` the executable name, `$3` the bundle identifier, and `$4` the user interface element flag (0/1). `$5` holds extra keys for the main app.
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
	<key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
	<key>LSEnvironment</key><dict><key>MallocNanoZone</key><string>0</string></dict>
	<key>LSUIElement</key><string>$4</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSSupportsAutomaticGraphicsSwitching</key><true/>
${5:-}
</dict>
</plist>
PLIST
}

# The main app registers to handle web links so the system can offer it as the default browser. Usage descriptions are required before the system requests camera, microphone, location, or Bluetooth access on a page's behalf; without one, macOS ends the app when Chromium reaches for that device, as it does for Bluetooth when a page signs in with a passkey on a phone. AppleScript reads the app's terms from the scripting definition in Resources.
APP_KEYS='	<key>CFBundleIconFile</key><string>Arch</string>
	<key>NSAppleScriptEnabled</key><true/>
	<key>OSAScriptingDefinition</key><string>Arch.sdef</string>
	<key>NSCameraUsageDescription</key><string>Web pages can use the camera after you allow them.</string>
	<key>NSMicrophoneUsageDescription</key><string>Web pages can use the microphone after you allow them.</string>
	<key>NSLocationUsageDescription</key><string>Web pages can use your location after you allow them.</string>
	<key>NSBluetoothAlwaysUsageDescription</key><string>Web pages can use Bluetooth, for example to sign in with a passkey on your phone.</string>
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
# SwiftPM records the deployment target as the SDK version, and macOS then runs the app with that older SDK's design, such as the old window buttons. Recording the SDK the app was built with gives it the current system design. vtool warns that this invalidates the signature; the bundle is signed at the end.
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
xcrun vtool -set-build-version macos "$MIN_MACOS" "$SDK_VERSION" -replace -output "$APP/Contents/MacOS/Arch.tmp" "$APP/Contents/MacOS/Arch"
mv "$APP/Contents/MacOS/Arch.tmp" "$APP/Contents/MacOS/Arch"
write_plist "$APP/Contents/Info.plist" "Arch" "local.arch.browser" 0 "$APP_KEYS"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp "$SDEF" "$APP/Contents/Resources/Arch.sdef"
cp -R "$CEF" "$APP/Contents/Frameworks/"

# Build the icon set from the 1024-pixel symbol. `opaque_icon.swift` fills its transparent corners so that macOS clips it to the system shape instead of placing it on a gray plate. Each size appears at 1x and 2x, as `iconutil` requires.
ICON_TEMP="$(mktemp -d)"
trap 'rm -rf "$ICON_TEMP"' EXIT
ICON_OPAQUE="$ICON_TEMP/icon.png"
swift "$ROOT/scripts/opaque_icon.swift" "$ICON_SOURCE" "$ICON_OPAQUE"
ICONSET="$ICON_TEMP/Arch.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ICON_OPAQUE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$ICON_OPAQUE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Arch.icns"

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
