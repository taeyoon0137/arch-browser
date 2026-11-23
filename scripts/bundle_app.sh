#!/bin/sh
# Assemble `build/Arch.app` using Swift Package Manager (SwiftPM) build products, among them `arch-cli`, and the Chromium Embedded Framework (CEF) distribution in `Frameworks/cef`.
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
[ -x "$BIN/arch-cli" ] || { echo "missing $BIN/arch-cli" >&2; exit 1; }
[ -d "$CEF" ] || { echo "missing CEF framework at $CEF" >&2; exit 1; }
[ -f "$ICON_SOURCE" ] || { echo "missing app icon source at $ICON_SOURCE" >&2; exit 1; }
[ -f "$SDEF" ] || { echo "missing scripting definition at $SDEF" >&2; exit 1; }
[ -d "$BIN/ArchBrowser_Arch.bundle" ] || { echo "missing the modules' resource bundles in $BIN; run swift build -c $CONFIG first" >&2; exit 1; }

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

# The languages the app lists are the ones its modules' string catalogs translate into; the system picks the app's language among them (`docs/localization.md`). The main app registers to handle web links so the system can offer it as the default browser. Usage descriptions are required before the system requests camera, microphone, location, or Bluetooth access on a page's behalf; without one, macOS ends the app when Chromium reaches for that device, as it does for Bluetooth when a page signs in with a passkey on a phone. AppleScript reads the app's terms from the scripting definition in Resources.
APP_KEYS='	<key>CFBundleIconFile</key><string>Arch</string>
	<key>CFBundleLocalizations</key><array><string>en</string><string>ko</string></array>
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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN/Arch" "$APP/Contents/MacOS/Arch"
# The agents' command-line tool, under the name SwiftPM gives it after its product. `arch-mcp` is the same executable through a relative link, which the signature seals as a link, so that Arch checks one code directory hash (docs/agents.md, agent decision 2).
cp "$BIN/arch-cli" "$APP/Contents/Helpers/arch-cli"
ln -s arch-cli "$APP/Contents/Helpers/arch-mcp"
# SwiftPM records the deployment target as the SDK version, and macOS then runs the app with that older SDK's design, such as the old window buttons. Recording the SDK the app was built with gives it the current system design. vtool warns that this invalidates the signature; the bundle is signed at the end.
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
xcrun vtool -set-build-version macos "$MIN_MACOS" "$SDK_VERSION" -replace -output "$APP/Contents/MacOS/Arch.tmp" "$APP/Contents/MacOS/Arch"
mv "$APP/Contents/MacOS/Arch.tmp" "$APP/Contents/MacOS/Arch"
write_plist "$APP/Contents/Info.plist" "Arch" "xyz.taeyoon.arch" 0 "$APP_KEYS"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp "$SDEF" "$APP/Contents/Resources/Arch.sdef"
# Each module's strings are in its own resource bundle, which the module looks for in Contents/Resources (`docs/localization.md`). The test targets' bundles stay out.
for bundle in "$BIN"/ArchBrowser_*.bundle; do
  case "$bundle" in *Tests.bundle) continue ;; esac
  cp -R "$bundle" "$APP/Contents/Resources/"
done
# The usage descriptions above in Korean, which the system shows when it asks for a device on a page's behalf.
mkdir -p "$APP/Contents/Resources/ko.lproj"
cat > "$APP/Contents/Resources/ko.lproj/InfoPlist.strings" <<'STRINGS'
"NSCameraUsageDescription" = "웹 페이지는 사용자가 허용한 후에 카메라를 사용할 수 있습니다.";
"NSMicrophoneUsageDescription" = "웹 페이지는 사용자가 허용한 후에 마이크를 사용할 수 있습니다.";
"NSLocationUsageDescription" = "웹 페이지는 사용자가 허용한 후에 사용자의 위치를 사용할 수 있습니다.";
"NSBluetoothAlwaysUsageDescription" = "웹 페이지는 Bluetooth를 사용할 수 있습니다. 예를 들어 휴대폰의 패스키로 로그인할 때 사용합니다.";
STRINGS
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
  write_plist "$helper/Contents/Info.plist" "$name" "xyz.taeyoon.arch.helper${idsuffix:+.$idsuffix}" 1
  printf 'APPL????' > "$helper/Contents/PkgInfo"
done

# A stable signing identity keeps the Keychain items Chromium creates readable across builds. Set `ARCH_SIGN_IDENTITY` to override the automatic choice. Otherwise, use the user's own developer team: the newest valid Developer ID Application identity, then the newest Apple Development identity, whose certificate names its holder as its organization, as an individual team's certificate does. Without one, use the first Apple Development identity on this Mac, or ad-hoc signing if none exists. The choice is passed as the certificate's SHA-1 hash, so nothing prints the identity's name or team.
# The `vtool` step above leaves the executable's signature invalid, and macOS does not run an executable so signed. A signing that fails, as with a mistyped identity or a locked keychain, therefore shows why and falls back to ad-hoc signing, and the script fails when that fails too. The script's own message leaves out the identity's name.
individual_identity() {
  security find-identity -v -p codesigning 2>/dev/null | python3 -I -c '
import re, subprocess, sys
pems = subprocess.run(["security", "find-certificate", "-a", "-Z", "-p"], capture_output=True, text=True).stdout
certs = dict(re.findall(r"SHA-1 hash: ([0-9A-F]{40})\n(-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----)", pems, re.S))
best = None
for sha, name in re.findall(r"\)\s+([0-9A-F]{40})\s+\"([^\"]+)\"", sys.stdin.read()):
    kind = name.split(":")[0]
    if kind not in ("Developer ID Application", "Apple Development") or sha not in certs:
        continue
    info = subprocess.run(["openssl", "x509", "-noout", "-subject", "-nameopt", "RFC2253", "-startdate"], input=certs[sha], capture_output=True, text=True).stdout
    organization = re.search(r"(?:^|[=,])O=([^,\n]+)", info)
    holder = re.sub(r"\s*\([A-Z0-9]{10}\)$", "", name.split(": ", 1)[-1])
    if not organization or organization.group(1).strip() != holder.strip():
        continue
    start = subprocess.run(["date", "-j", "-f", "%b %d %H:%M:%S %Y %Z", re.search(r"notBefore=(.+)", info).group(1).strip(), "+%s"], capture_output=True, text=True).stdout.strip()
    rank = (kind == "Developer ID Application", int(start or 0))
    if best is None or rank > best[0]:
        best = (rank, sha)
print(best[1] if best else "")
'
}
IDENTITY="${ARCH_SIGN_IDENTITY:-$(individual_identity)}"
IDENTITY="${IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -n 1)}"

# iCloud (CloudKit) and push need entitlements that only a provisioning profile grants (`docs/sync.md`, Requirements); `scripts/provision_app.sh` gets the profiles. A profile suits the signing identity when it is for `xyz.taeyoon.arch` on macOS, has not expired, lists the identity's certificate, and matches its kind: a Developer ID profile for a Developer ID Application identity, and a development profile that lists this Mac for an Apple Development identity. The newest suitable profile in Xcode's profile folder is used, or the one at `ARCH_PROVISIONING_PROFILE`, which must suit. The script embeds it as `Contents/embedded.provisionprofile` and signs the app with entitlements written to `build/Arch.entitlements` from the ones the profile grants: the application and team identifiers, the iCloud containers with CloudKit and their environment (Production for Developer ID, as Xcode's export chooses, and Development otherwise) when the profile grants a container and CloudKit, and the push environment when it grants push. The script says which of these the app got and warns when the profile grants no iCloud container. The bundle has no other entitlements. Without a suitable profile, the app is signed as before, with none.
PROFILE_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
ENTITLEMENTS="$ROOT/build/Arch.entitlements"

# Arguments: `$1` is the SHA-1 hash of the identity's certificate, `$2` the identity's kind, `$3` this Mac's provisioning UDID, `$4` 1 to say on standard error why a profile does not suit, and the rest the profiles to consider. Prints the newest suitable profile's path.
matching_profile() {
  python3 -I -c '
import datetime, hashlib, plistlib, subprocess, sys
sha, kind, udid, explain = sys.argv[1:5]
now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
best = None
for path in sys.argv[5:]:
    try:
        profile = plistlib.loads(subprocess.run(["security", "cms", "-D", "-i", path], capture_output=True).stdout)
    except Exception:
        profile = {}
    granted = profile.get("Entitlements", {})
    team = granted.get("com.apple.developer.team-identifier", "")
    certificates = {hashlib.sha1(c).hexdigest().upper() for c in profile.get("DeveloperCertificates", [])}
    everywhere = profile.get("ProvisionsAllDevices", False)
    if not profile:
        problem = "it is not a provisioning profile"
    elif not team or granted.get("com.apple.application-identifier") != team + ".xyz.taeyoon.arch" or "OSX" not in profile.get("Platform", []):
        problem = "it is not for xyz.taeyoon.arch on macOS"
    elif profile.get("ExpirationDate", now) <= now:
        problem = "it has expired"
    elif sha not in certificates:
        problem = "it does not list the signing certificate"
    elif everywhere != (kind == "Developer ID Application"):
        problem = "it is a " + ("Developer ID" if everywhere else "development") + " profile, and the identity is " + kind
    elif not everywhere and udid not in profile.get("ProvisionedDevices", []):
        problem = "it does not list this Mac"
    else:
        problem = None
    if problem:
        if explain == "1":
            print("the provisioning profile does not suit the signing identity: " + problem, file=sys.stderr)
        continue
    if best is None or profile.get("CreationDate", now) > best[0]:
        best = (profile.get("CreationDate", now), path)
print(best[1] if best else "")
' "$@"
}

# Writes the app's entitlements, as a property list at `$3`, from the ones the profile at `$1` grants, for an identity of kind `$2`, and prints which iCloud and push entitlements they hold. A profile grants patterns, such as `*` for every iCloud service; the app names the values it uses.
profile_entitlements() {
  security cms -D -i "$1" 2>/dev/null | python3 -I -c '
import plistlib, sys
kind, path = sys.argv[1:3]
granted = plistlib.loads(sys.stdin.buffer.read())["Entitlements"]
entitlements = {key: granted[key] for key in ("com.apple.application-identifier", "com.apple.developer.team-identifier")}
services = granted.get("com.apple.developer.icloud-services", [])
containers = sorted((c for c in granted.get("com.apple.developer.icloud-container-identifiers", []) if "*" not in c), key=lambda c: c != "iCloud.xyz.taeyoon.arch")
if containers and (services == "*" or "CloudKit" in services):
    entitlements["com.apple.developer.icloud-container-identifiers"] = containers
    entitlements["com.apple.developer.icloud-services"] = ["CloudKit"]
    environments = granted.get("com.apple.developer.icloud-container-environment", [])
    environments = [environments] if isinstance(environments, str) else environments
    wanted = "Production" if kind == "Developer ID Application" else "Development"
    if environments:
        entitlements["com.apple.developer.icloud-container-environment"] = wanted if wanted in environments else environments[0]
if "com.apple.developer.aps-environment" in granted:
    entitlements["com.apple.developer.aps-environment"] = granted["com.apple.developer.aps-environment"]
with open(path, "wb") as file:
    plistlib.dump(entitlements, file)
container = "iCloud.xyz.taeyoon.arch" in entitlements.get("com.apple.developer.icloud-container-identifiers", [])
print("iCloud container: " + ("yes" if container else "no") + ", CloudKit environment: " + entitlements.get("com.apple.developer.icloud-container-environment", "not set") + ", push: " + entitlements.get("com.apple.developer.aps-environment", "no"))
' "$2" "$3"
}

PROFILE=""
CERT_KIND=""
rm -f "$ENTITLEMENTS"
if [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ]; then
  # The identity is a certificate's SHA-1 hash or part of its name, as `codesign` takes it.
  case "$IDENTITY" in
    *[!0-9A-Fa-f]*) LOOKUP="$IDENTITY" ;;
    *) LOOKUP="$(printf '%s' "$IDENTITY" | tr 'a-f' 'A-F')" ;;
  esac
  IDENTITY_LINE="$(security find-identity -v -p codesigning 2>/dev/null | grep -F -- "$LOOKUP" | head -n 1 || true)"
  CERT_SHA="$(printf '%s\n' "$IDENTITY_LINE" | sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) ".*/\1/p')"
  CERT_KIND="$(printf '%s\n' "$IDENTITY_LINE" | sed -n 's/^[^"]*"\([^:"]*\):.*/\1/p')"
  UDID=""
  [ "$CERT_KIND" = "Developer ID Application" ] || UDID="$(system_profiler SPHardwareDataType 2>/dev/null | sed -n 's/^ *Provisioning UDID: //p')"
  if [ -n "${ARCH_PROVISIONING_PROFILE:-}" ]; then
    PROFILE="$(matching_profile "$CERT_SHA" "$CERT_KIND" "$UDID" 1 "$ARCH_PROVISIONING_PROFILE")"
  else
    PROFILE="$(matching_profile "$CERT_SHA" "$CERT_KIND" "$UDID" 0 "$PROFILE_DIR"/*.provisionprofile)"
  fi
fi
if [ -n "${ARCH_PROVISIONING_PROFILE:-}" ] && [ -z "$PROFILE" ]; then
  echo "ARCH_PROVISIONING_PROFILE is set, but its profile cannot be used with the signing identity; the app is not signed" >&2
  exit 1
fi
if [ -n "$PROFILE" ]; then
  cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
  GRANTED="$(profile_entitlements "$PROFILE" "$CERT_KIND" "$ENTITLEMENTS")"
  echo "embedding the provisioning profile for the $CERT_KIND identity; entitlements: $GRANTED" >&2
  case "$GRANTED" in
    "iCloud container: no"*) echo "the profile grants no iCloud container with CloudKit, so the app has no iCloud entitlements; scripts/provision_app.sh says how to assign the container to the App ID" >&2 ;;
  esac
elif [ -n "$CERT_KIND" ]; then
  echo "no provisioning profile suits the $CERT_KIND identity, so the app has no iCloud or push entitlements; scripts/provision_app.sh gets one" >&2
fi

# With a profile, `--deep` signs the helper apps and the framework without its entitlements, and the second signing gives them to the app alone.
if ! SIGN_OUTPUT="$(codesign --force --deep --sign "${IDENTITY:--}" "$APP" 2>&1)" ||
  { [ -n "$PROFILE" ] && ! SIGN_OUTPUT="$(codesign --force --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" "$APP" 2>&1)"; }; then
  printf '%s\n' "$SIGN_OUTPUT" >&2
  echo "signing failed; signing ad hoc instead, without the provisioning profile, so the Keychain items Chromium created under the identity may ask for access" >&2
  rm -f "$APP/Contents/embedded.provisionprofile" "$ENTITLEMENTS"
  codesign --force --deep --sign - "$APP"
fi
echo "$APP"
