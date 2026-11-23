#!/bin/sh
# Assemble `build/Arch.app` using Swift Package Manager (SwiftPM) build products, among them `arch-cli`, and the Chromium Embedded Framework (CEF) distribution in `Frameworks/cef`, with the Sparkle framework that SwiftPM fetches for app updates.
# Usage: scripts/bundle_app.sh [debug|release]
# `ARCH_HARDENED_RUNTIME=1` signs every executable with the hardened runtime and a secure timestamp, as notarization requires (`docs/updates.md`, Notarization). It is off by default.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
BIN="$ROOT/.build/$CONFIG"
CEF="$ROOT/Frameworks/cef/Release/Chromium Embedded Framework.framework"
ICON_SOURCE="$ROOT/resources/assets/sym_arch.png"
SDEF="$ROOT/Packages/ARCHApp/Sources/Arch/Arch.sdef"
APP="$ROOT/build/Arch.app"
VERSION="0.1.0"
# The build number is the build's time in UTC, as YYYYMMDDHHMM, so it only grows, whatever happens to the git history (a squash or a rebase can lower a commit count). The About window shows it with the build's commit, with + when the tree had uncommitted changes.
BUILD_NUMBER="$(date -u +%Y%m%d%H%M)"
BUILD_COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
git -C "$ROOT" diff --quiet HEAD -- 2>/dev/null || BUILD_COMMIT="$BUILD_COMMIT+"
MIN_MACOS="14.0"
# Sparkle checks this appcast, which `scripts/release_app.sh` uploads to each GitHub release, and installs only archives signed with the private key of this EdDSA public key (`docs/updates.md`). The public key is the one `generate_keys --account <account>` prints; `ARCH_SPARKLE_PUBLIC_KEY` overrides it. Without a key, the app has no updater.
SPARKLE="$BIN/Sparkle.framework"
SPARKLE_FEED_URL="https://github.com/taeyoon0137/arch-browser/releases/latest/download/appcast.xml"
SPARKLE_PUBLIC_KEY="${ARCH_SPARKLE_PUBLIC_KEY:-qcqorQoz1m8ybNW/E6Z6AQuSWvWip65LJfKoqKxXamw=}"

[ -x "$BIN/Arch" ] || { echo "missing $BIN/Arch; run swift build -c $CONFIG first" >&2; exit 1; }
[ -x "$BIN/ArchHelper" ] || { echo "missing $BIN/ArchHelper" >&2; exit 1; }
[ -x "$BIN/arch-cli" ] || { echo "missing $BIN/arch-cli" >&2; exit 1; }
[ -d "$CEF" ] || { echo "missing CEF framework at $CEF" >&2; exit 1; }
[ -f "$ICON_SOURCE" ] || { echo "missing app icon source at $ICON_SOURCE" >&2; exit 1; }
[ -f "$SDEF" ] || { echo "missing scripting definition at $SDEF" >&2; exit 1; }
[ -d "$BIN/ArchBrowser_Arch.bundle" ] || { echo "missing the modules' resource bundles in $BIN; run swift build -c $CONFIG first" >&2; exit 1; }
[ -d "$SPARKLE" ] || { echo "missing Sparkle framework at $SPARKLE; run swift build -c $CONFIG first" >&2; exit 1; }
[ -n "$SPARKLE_PUBLIC_KEY" ] || echo "no Sparkle public key is set, so the app has no updater; docs/updates.md says how to make the key pair" >&2

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
	<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
	<key>ArchBuildCommit</key><string>$BUILD_COMMIT</string>
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
# Sparkle checks once a day without asking first, and sends no system profile with its checks (`docs/updates.md`).
APP_KEYS="$APP_KEYS
	<key>SUFeedURL</key><string>$SPARKLE_FEED_URL</string>
	<key>SUEnableAutomaticChecks</key><true/>
	<key>SUScheduledCheckInterval</key><integer>86400</integer>
	<key>SUEnableSystemProfiling</key><false/>"
[ -z "$SPARKLE_PUBLIC_KEY" ] || APP_KEYS="$APP_KEYS
	<key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>"

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
# The app links Sparkle through `@rpath`, which SwiftPM points at its build folders. In the bundle the framework is in Contents/Frameworks, and the build folder's path stays out of the app.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Arch" 2>/dev/null
otool -l "$APP/Contents/MacOS/Arch" | sed -n 's/^ *path \(.*\) (offset [0-9]*)$/\1/p' | while IFS= read -r rpath; do
  case "$rpath" in "$ROOT"/*) install_name_tool -delete_rpath "$rpath" "$APP/Contents/MacOS/Arch" 2>/dev/null ;; esac
done
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

# Signs Sparkle's framework in the bundle with identity `$1`, from the inside out, as Sparkle's documentation does: the XPC services, the Autoupdate helper, the Updater app, and then the framework, each with the hardened runtime that Sparkle's own signatures have. Only the downloader service keeps its entitlements.
# A hardened build also gives each signature a secure timestamp, which notarization requires.
sign_sparkle() {
  versions="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
  codesign --force --sign "$1" --options runtime ${TIMESTAMP:+--timestamp} "$versions/XPCServices/Installer.xpc" &&
    codesign --force --sign "$1" --options runtime ${TIMESTAMP:+--timestamp} --preserve-metadata=entitlements "$versions/XPCServices/Downloader.xpc" &&
    codesign --force --sign "$1" --options runtime ${TIMESTAMP:+--timestamp} "$versions/Autoupdate" &&
    codesign --force --sign "$1" --options runtime ${TIMESTAMP:+--timestamp} "$versions/Updater.app" &&
    codesign --force --sign "$1" --options runtime ${TIMESTAMP:+--timestamp} "$APP/Contents/Frameworks/Sparkle.framework"
}

# Signs the bundle with identity `$1`, and the app with the entitlements at `$2` when it is not empty. `--deep` signs the helper apps and the CEF framework without entitlements, so Sparkle's framework joins the bundle after it, keeping the entitlements and runtime of its signatures, and the last signing seals the app with both.
sign_app() {
  rm -rf "$APP/Contents/Frameworks/Sparkle.framework"
  codesign --force --deep --sign "$1" "$APP" &&
    ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework" &&
    sign_sparkle "$1" &&
    codesign --force --sign "$1" ${2:+--entitlements "$2"} "$APP"
}

# The hardened runtime's entitlements follow Chromium's own macOS signing configuration and entitlement files in the pinned Chromium source. Each key has its reason:
# - The renderer and GPU helpers get `com.apple.security.cs.allow-jit`. V8 and WebAssembly in the renderer, and SwiftShader's code generator in the GPU process, write code to memory that they map with `MAP_JIT`, which the hardened runtime allows only with this key. Chromium gives these two helpers this key alone: `com.apple.security.cs.allow-unsigned-executable-memory` is not needed, because no part maps executable memory without `MAP_JIT`.
# - The base helper, which runs the utility processes (network, storage, audio, and video capture), and the Alerts helper get none, as in Chromium. The Plugin helper gets none: the pinned Chromium launches only the base, renderer, and GPU helpers, so CEF's Plugin helper never runs.
# - The app keeps the provisioning profile's entitlements (`docs/sync.md`) and adds the hardened runtime's resource keys for what pages may use after the user allows them, as Chromium's app does: `com.apple.security.device.audio-input` for the microphone, `com.apple.security.device.camera` for the camera, and `com.apple.security.personal-information.location` for location, which the browser process reads through Core Location. Without them, macOS denies those devices to a hardened app whatever the user allows. Bluetooth, USB, and printing have no hardened runtime key; Chromium's keys for them are App Sandbox keys, and Arch has no sandbox. The app sends no Apple Events, so it has no `com.apple.security.automation.apple-events`. It gets no `allow-jit`: WebKit pages run in the system's own WebKit processes, and the plugins' syntax checks run JavaScriptCore in the app, which runs code without its compiler when the process may not map `MAP_JIT` memory.
# - No executable gets `com.apple.security.cs.disable-library-validation`: the script signs the CEF framework, its libraries, and Sparkle's framework with the app's own identity, so library validation accepts them.
# Ad-hoc signing has no team, so library validation would refuse the frameworks, and the notary service accepts only Developer ID; a hardened build therefore fails instead of falling back to ad-hoc signing.
HARDENED="${ARCH_HARDENED_RUNTIME:-0}"
TIMESTAMP=""
JIT_ENTITLEMENTS="$ROOT/build/ArchHelperJIT.entitlements"
rm -f "$JIT_ENTITLEMENTS"

# Writes the hardened app's entitlements at `$1`: the profile's, when the script wrote them there, and the resource keys above.
hardened_app_entitlements() {
  python3 -I -c '
import os, plistlib, sys
path = sys.argv[1]
entitlements = {}
if os.path.exists(path):
    with open(path, "rb") as file:
        entitlements = plistlib.load(file)
for key in ("com.apple.security.device.audio-input", "com.apple.security.device.camera", "com.apple.security.personal-information.location"):
    entitlements[key] = True
with open(path, "wb") as file:
    plistlib.dump(entitlements, file)
' "$1"
}

# Signs the bundle with identity `$1` from the inside out, each part with the hardened runtime and a secure timestamp: the CEF framework's libraries and the framework, the helper apps with their entitlements, `arch-cli`, Sparkle's framework, and last the app with the entitlements at `$2`.
sign_hardened() {
  cef="$APP/Contents/Frameworks/Chromium Embedded Framework.framework"
  for lib in "$cef/Libraries/"*.dylib; do
    codesign --force --sign "$1" --options runtime --timestamp "$lib" || return 1
  done
  codesign --force --sign "$1" --options runtime --timestamp "$cef" || return 1
  for suffix in "" " (GPU)" " (Renderer)" " (Plugin)" " (Alerts)"; do
    case "$suffix" in
      " (GPU)" | " (Renderer)") helper_entitlements="$JIT_ENTITLEMENTS" ;;
      *) helper_entitlements="" ;;
    esac
    codesign --force --sign "$1" --options runtime --timestamp ${helper_entitlements:+--entitlements "$helper_entitlements"} "$APP/Contents/Frameworks/Arch Helper$suffix.app" || return 1
  done
  codesign --force --sign "$1" --options runtime --timestamp "$APP/Contents/Helpers/arch-cli" &&
    rm -rf "$APP/Contents/Frameworks/Sparkle.framework" &&
    ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework" &&
    sign_sparkle "$1" &&
    codesign --force --sign "$1" --options runtime --timestamp --entitlements "$2" "$APP"
}

if [ "$HARDENED" = "1" ]; then
  [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ] || { echo "ARCH_HARDENED_RUNTIME=1 needs a signing identity, and none was found; a hardened build is not signed ad hoc" >&2; exit 1; }
  TIMESTAMP=1
  mkdir -p "$ROOT/build"
  cat > "$JIT_ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.cs.allow-jit</key>
	<true/>
</dict>
</plist>
PLIST
  hardened_app_entitlements "$ENTITLEMENTS"
  if ! SIGN_OUTPUT="$(sign_hardened "$IDENTITY" "$ENTITLEMENTS" 2>&1)"; then
    printf '%s\n' "$SIGN_OUTPUT" >&2
    echo "hardened signing failed; the bundle is not signed" >&2
    exit 1
  fi
  echo "signed with the hardened runtime; the renderer and GPU helpers may compile code, and the app may use the camera, microphone, and location" >&2
elif ! SIGN_OUTPUT="$(sign_app "${IDENTITY:--}" "${PROFILE:+$ENTITLEMENTS}" 2>&1)"; then
  printf '%s\n' "$SIGN_OUTPUT" >&2
  echo "signing failed; signing ad hoc instead, without the provisioning profile, so the Keychain items Chromium created under the identity may ask for access" >&2
  rm -f "$APP/Contents/embedded.provisionprofile" "$ENTITLEMENTS"
  sign_app - ""
fi
codesign --verify --deep --strict "$APP"
echo "$APP"
