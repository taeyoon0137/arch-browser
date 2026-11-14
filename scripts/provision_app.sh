#!/bin/sh
# Get the provisioning profiles that let `scripts/bundle_app.sh` give Arch the iCloud (CloudKit) and push entitlements:
# a Mac development profile through a build, and a Developer ID profile through an archive and its export. Xcode makes
# and downloads profiles only for a project, so the script writes a stand-in project with Arch's bundle identifier and
# entitlements into a temporary folder, builds it with automatic signing, and deletes the folder; the repository holds
# no project files. `--dry-run` writes and checks the project, prints the commands, and reports the installed profiles
# without running them.
# Usage: scripts/provision_app.sh [--dry-run]
# Xcode signs in with the Apple Account in Xcode ▸ Settings ▸ Accounts, or with an App Store Connect API key when
# `ARCH_ASC_KEY_ID` and `ARCH_ASC_ISSUER_ID` are set. `ARCH_ASC_KEY_PATH` is the key's path and defaults to
# `~/.appstoreconnect/private_keys/AuthKey_<key id>.p8`; the script reads the key there and never copies it. Output
# names no team, name, email address, or key identifier: only whether each profile exists, what it allows, and when it
# expires.
set -eu
BUNDLE_ID="xyz.taeyoon.arch"
CONTAINER="iCloud.xyz.taeyoon.arch"
PROFILES="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"

DRY_RUN=0
case "${1:-}" in
  "") ;;
  --dry-run) DRY_RUN=1 ;;
  *) echo "usage: scripts/provision_app.sh [--dry-run]" >&2; exit 2 ;;
esac

# The user's own individual team, chosen as `scripts/bundle_app.sh` chooses its identity: the newest valid Developer ID
# Application identity, then the newest Apple Development identity, whose certificate names its holder as its
# organization. The certificate's organizational unit is the team. Prints the team and the holder, separated by a tab,
# for the script to pass to Xcode and to remove from what it shows.
individual_team() {
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
    team = re.search(r"(?:^|[=,])OU=([^,\n]+)", info)
    holder = re.sub(r"\s*\([A-Z0-9]{10}\)$", "", name.split(": ", 1)[-1])
    if not organization or not team or organization.group(1).strip() != holder.strip():
        continue
    start = subprocess.run(["date", "-j", "-f", "%b %d %H:%M:%S %Y %Z", re.search(r"notBefore=(.+)", info).group(1).strip(), "+%s"], capture_output=True, text=True).stdout.strip()
    rank = (kind == "Developer ID Application", int(start or 0))
    if best is None or rank > best[0]:
        best = (rank, team.group(1).strip() + "\t" + holder.strip())
print(best[1] if best else "")
'
}

explain_credentials() {
  cat >&2 <<'TEXT'

Xcode could not sign in to your Apple Developer account. Give it access in one of two ways, then run
./scripts/provision_app.sh again:

1. Sign in again in Xcode: open Xcode, choose Xcode > Settings > Accounts, select your Apple Account, and sign in
   when Xcode asks. If it does not ask, remove the account with the minus button and add it again with the plus
   button.
2. Or use an App Store Connect API key: in App Store Connect, open Users and Access > Integrations > App Store
   Connect API, create a team key with Admin access, and download it (Apple offers the download only once). Move
   the downloaded AuthKey_<key id>.p8 file into ~/.appstoreconnect/private_keys/, then run
     ARCH_ASC_KEY_ID=<key id> ARCH_ASC_ISSUER_ID=<issuer id> ./scripts/provision_app.sh
   The issuer ID is shown above the list of keys. Set ARCH_ASC_KEY_PATH as well if you keep the key elsewhere.
TEXT
}

CHOICE="$(individual_team)"
if [ -z "$CHOICE" ]; then
  cat >&2 <<'TEXT'
This Mac has no Developer ID Application or Apple Development certificate of your own team, so the script cannot
tell Xcode which team to use. Sign in to your Apple Account in Xcode > Settings > Accounts, choose Manage
Certificates, add an Apple Development certificate with the plus button, then run ./scripts/provision_app.sh again.
TEXT
  exit 1
fi
TEAM="${CHOICE%%	*}"
HOLDER="${CHOICE#*	}"

KEY_ID="${ARCH_ASC_KEY_ID:-}"
ISSUER_ID="${ARCH_ASC_ISSUER_ID:-}"
KEY_PATH=""
if [ -n "$KEY_ID" ] || [ -n "$ISSUER_ID" ]; then
  if [ -z "$KEY_ID" ] || [ -z "$ISSUER_ID" ]; then
    echo "Set both ARCH_ASC_KEY_ID and ARCH_ASC_ISSUER_ID to use an App Store Connect API key." >&2
    exit 1
  fi
  KEY_PATH="${ARCH_ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$KEY_ID.p8}"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd -P)"

# Replaces the team, the holder, the key and issuer identifiers, email addresses, certificate names, and anything that
# looks like a team identifier, and shortens the temporary folder.
redact() {
  REDACT_TEAM="$TEAM" REDACT_HOLDER="$HOLDER" REDACT_KEY="$KEY_ID" REDACT_ISSUER="$ISSUER_ID" REDACT_WORK="${WORK#/private}" perl -pe '
    s/(?:\/private)?\Q$ENV{REDACT_WORK}\E/<stand-in>/g;
    s/\Q$ENV{REDACT_TEAM}\E/<team>/g;
    s/\Q$ENV{REDACT_HOLDER}\E/<holder>/g;
    s/\Q$ENV{REDACT_KEY}\E/<key id>/g if length $ENV{REDACT_KEY};
    s/\Q$ENV{REDACT_ISSUER}\E/<issuer id>/g if length $ENV{REDACT_ISSUER};
    s/[\w.+-]+@[\w-]+(?:\.[\w-]+)+/<email>/g;
    s/((?:Apple Development|Apple Distribution|Developer ID Application|Developer ID Installer|Mac Developer|Mac App Distribution|Mac Installer Distribution)): [^"\x27\n]+/$1: <redacted>/g;
    s/\b(?=[A-Z]*[0-9])(?=[0-9]*[A-Z])[A-Z0-9]{10}\b/<redacted>/g;
  '
}

# The stand-in: one macOS app target with Arch's bundle identifier, automatic signing, and the entitlements that sync
# needs. The team comes from the command line, so no file holds it.
mkdir -p "$WORK/App" "$WORK/ArchProv.xcodeproj"
printf 'print("provisioning stand-in for Arch")\n' > "$WORK/App/main.swift"
cat > "$WORK/App/Arch.entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.developer.aps-environment</key><string>development</string>
	<key>com.apple.developer.icloud-container-identifiers</key><array><string>$CONTAINER</string></array>
	<key>com.apple.developer.icloud-services</key><array><string>CloudKit</string></array>
</dict>
</plist>
PLIST
cat > "$WORK/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>developer-id</string>
	<key>signingStyle</key><string>automatic</string>
	<key>destination</key><string>export</string>
	<key>iCloudContainerEnvironment</key><string>Production</string>
</dict>
</plist>
PLIST
TARGET_SETTINGS="PRODUCT_BUNDLE_IDENTIFIER = $BUNDLE_ID; PRODUCT_NAME = Arch; GENERATE_INFOPLIST_FILE = YES; CODE_SIGN_STYLE = Automatic; CODE_SIGN_ENTITLEMENTS = App/Arch.entitlements; CODE_SIGN_IDENTITY = \"Apple Development\"; ENABLE_HARDENED_RUNTIME = YES; COMBINE_HIDPI_IMAGES = YES;"
PROJECT_SETTINGS="SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 14.0; SWIFT_VERSION = 5.0; ALWAYS_SEARCH_USER_PATHS = NO;"
cat > "$WORK/ArchProv.xcodeproj/project.pbxproj" <<PBXPROJ
// !\$*UTF8*\$!
{
	archiveVersion = 1;
	classes = {
	};
	objectVersion = 56;
	objects = {
		A10000000000000000000001 = {isa = PBXBuildFile; fileRef = A10000000000000000000002; };
		A10000000000000000000002 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = main.swift; sourceTree = "<group>"; };
		A10000000000000000000003 = {isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = Arch.entitlements; sourceTree = "<group>"; };
		A10000000000000000000004 = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Arch.app; sourceTree = BUILT_PRODUCTS_DIR; };
		A10000000000000000000010 = {isa = PBXGroup; children = (A10000000000000000000011, A10000000000000000000012, ); sourceTree = "<group>"; };
		A10000000000000000000011 = {isa = PBXGroup; children = (A10000000000000000000002, A10000000000000000000003, ); path = App; sourceTree = "<group>"; };
		A10000000000000000000012 = {isa = PBXGroup; children = (A10000000000000000000004, ); name = Products; sourceTree = "<group>"; };
		A10000000000000000000020 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (A10000000000000000000001, ); runOnlyForDeploymentPostprocessing = 0; };
		A10000000000000000000030 = {isa = PBXNativeTarget; buildConfigurationList = A10000000000000000000041; buildPhases = (A10000000000000000000020, ); buildRules = ( ); dependencies = ( ); name = Arch; productName = Arch; productReference = A10000000000000000000004; productType = "com.apple.product-type.application"; };
		A10000000000000000000031 = {isa = PBXProject; attributes = {BuildIndependentTargetsInParallel = 1; LastUpgradeCheck = 2700; }; buildConfigurationList = A10000000000000000000040; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base, ); mainGroup = A10000000000000000000010; productRefGroup = A10000000000000000000012; projectDirPath = ""; projectRoot = ""; targets = (A10000000000000000000030, ); };
		A10000000000000000000050 = {isa = XCBuildConfiguration; buildSettings = {$PROJECT_SETTINGS ONLY_ACTIVE_ARCH = YES; }; name = Debug; };
		A10000000000000000000051 = {isa = XCBuildConfiguration; buildSettings = {$PROJECT_SETTINGS }; name = Release; };
		A10000000000000000000052 = {isa = XCBuildConfiguration; buildSettings = {$TARGET_SETTINGS }; name = Debug; };
		A10000000000000000000053 = {isa = XCBuildConfiguration; buildSettings = {$TARGET_SETTINGS }; name = Release; };
		A10000000000000000000040 = {isa = XCConfigurationList; buildConfigurations = (A10000000000000000000050, A10000000000000000000051, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
		A10000000000000000000041 = {isa = XCConfigurationList; buildConfigurations = (A10000000000000000000052, A10000000000000000000053, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
	};
	rootObject = A10000000000000000000031;
}
PBXPROJ

xcodebuild_with_credentials() {
  if [ -n "$KEY_ID" ]; then
    xcodebuild "$@" -authenticationKeyPath "$KEY_PATH" -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER_ID"
  else
    xcodebuild "$@"
  fi
}

# Runs one xcodebuild step named `$1` and keeps its output in memory. A failed step shows its errors without the
# team, names, or identifiers, and notes whether signing in failed.
SIGN_IN_FAILED=0
run_step() {
  name="$1"
  shift
  if [ "$DRY_RUN" = 1 ]; then
    printf '%s: xcodebuild %s%s\n' "$name" "$*" "${KEY_ID:+ -authenticationKeyPath $KEY_PATH -authenticationKeyID $KEY_ID -authenticationKeyIssuerID $ISSUER_ID}" | redact
    return 0
  fi
  printf '%s: ' "$name"
  if output="$(xcodebuild_with_credentials "$@" 2>&1)"; then
    echo "succeeded"
    return 0
  fi
  echo "failed"
  printf '%s\n' "$output" | grep -E 'error:|Failed to load credentials' | sed 's/^.*DVTDeveloperAccountManager: *//' | redact | awk '!seen[$0]++' | head -n 12 | sed 's/^/  /'
  if printf '%s\n' "$output" | grep -q -i -E 'No Accounts|Xcode-Token|Xcode-Username|credentials|not signed in|sign in|log in|authenticat|session has expired|No account for team'; then
    SIGN_IN_FAILED=1
  fi
  return 1
}

# Copies the profile Xcode embedded in an app at `$1` into Xcode's profile folder, where `scripts/bundle_app.sh` looks,
# unless Xcode already installed it there.
install_profile() {
  embedded="$1/Contents/embedded.provisionprofile"
  [ -f "$embedded" ] || return 0
  uuid="$(security cms -D -i "$embedded" 2>/dev/null | plutil -extract UUID raw -o - - 2>/dev/null || true)"
  [ -n "$uuid" ] || return 0
  mkdir -p "$PROFILES"
  [ -f "$PROFILES/$uuid.provisionprofile" ] || cp "$embedded" "$PROFILES/$uuid.provisionprofile"
}

# Reports the newest current profile of each kind for the bundle identifier and the team, with yes or no for what it
# allows, and its expiry date.
report() {
  REPORT_TEAM="$TEAM" python3 -I -c '
import datetime, hashlib, os, plistlib, re, subprocess, sys
folder, bundle, container = sys.argv[1:4]
team = os.environ["REPORT_TEAM"]
listing = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"], capture_output=True, text=True).stdout
local = set(re.findall(r"\)\s+([0-9A-F]{40})\s+\"", listing))
hardware = subprocess.run(["system_profiler", "SPHardwareDataType"], capture_output=True, text=True).stdout
udid = (re.findall(r"Provisioning UDID: (\S+)", hardware) or [""])[0]
now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
yes = lambda value: "yes" if value else "no"
found = {"Development": [], "Developer ID": []}
names = sorted(os.listdir(folder)) if os.path.isdir(folder) else []
for name in names:
    if not name.endswith(".provisionprofile"):
        continue
    data = subprocess.run(["security", "cms", "-D", "-i", os.path.join(folder, name)], capture_output=True).stdout
    try:
        profile = plistlib.loads(data)
    except Exception:
        continue
    granted = profile.get("Entitlements", {})
    if granted.get("com.apple.application-identifier") != team + "." + bundle or "OSX" not in profile.get("Platform", []):
        continue
    found["Developer ID" if profile.get("ProvisionsAllDevices") else "Development"].append(profile)
print("Provisioning profiles for " + bundle + " on this Mac: " + str(sum(len(p) for p in found.values())))
for kind, profiles in found.items():
    current = [p for p in profiles if p.get("ExpirationDate", now) > now]
    if not current:
        print(kind + " profile: not found" + (" (" + str(len(profiles)) + " expired)" if profiles else ""))
        continue
    profile = max(current, key=lambda p: p.get("CreationDate", now))
    granted = profile["Entitlements"]
    services = granted.get("com.apple.developer.icloud-services", [])
    certificates = {hashlib.sha1(c).hexdigest().upper() for c in profile.get("DeveloperCertificates", [])}
    parts = [kind + " profile: found", "certificate on this Mac: " + yes(certificates & local)]
    if kind == "Development":
        parts.append("this Mac registered: " + yes(udid and udid in profile.get("ProvisionedDevices", [])))
    parts += [
        "iCloud container: " + yes(container in granted.get("com.apple.developer.icloud-container-identifiers", [])),
        "CloudKit: " + yes(services == "*" or "CloudKit" in services),
        "push: " + granted.get("com.apple.developer.aps-environment", "no"),
        "expires " + profile["ExpirationDate"].strftime("%Y-%m-%d"),
    ]
    print(", ".join(parts))
' "$PROFILES" "$BUNDLE_ID" "$CONTAINER"
}

PROJECT="$WORK/ArchProv.xcodeproj"
DERIVED="$WORK/DerivedData"
ARCHIVE="$WORK/Arch.xcarchive"
echo "Signing team: found (not shown)"
if [ -n "$KEY_ID" ]; then
  [ -f "$KEY_PATH" ] && KEY_FOUND=yes || KEY_FOUND=no
  echo "Credentials: App Store Connect API key, key file found: $KEY_FOUND"
  if [ "$KEY_FOUND" = no ] && [ "$DRY_RUN" = 0 ]; then
    echo "The key file is not at ARCH_ASC_KEY_PATH or at ~/.appstoreconnect/private_keys/AuthKey_<key id>.p8." >&2
    explain_credentials
    exit 1
  fi
else
  echo "Credentials: the Apple Account in Xcode > Settings > Accounts"
fi

if [ "$DRY_RUN" = 1 ]; then
  if xcodebuild -list -project "$PROJECT" 2>/dev/null | grep -q -E '^[[:space:]]+Arch$'; then SCHEME=yes; else SCHEME=no; fi
  echo "Stand-in project: written, Arch scheme found: $SCHEME"
fi

STATUS=0
if run_step "Development profile (build)" -project "$PROJECT" -scheme Arch -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration DEVELOPMENT_TEAM="$TEAM" build; then
  [ "$DRY_RUN" = 1 ] || install_profile "$DERIVED/Build/Products/Debug/Arch.app"
else
  STATUS=1
fi
if [ "$SIGN_IN_FAILED" = 0 ]; then
  if run_step "Archive" -project "$PROJECT" -scheme Arch -configuration Release \
    -destination "generic/platform=macOS" -derivedDataPath "$DERIVED" -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration DEVELOPMENT_TEAM="$TEAM" archive &&
    run_step "Developer ID profile (export)" -exportArchive -archivePath "$ARCHIVE" -exportPath "$WORK/export" \
      -exportOptionsPlist "$WORK/ExportOptions.plist" -allowProvisioningUpdates; then
    [ "$DRY_RUN" = 1 ] || install_profile "$WORK/export/Arch.app"
  else
    STATUS=1
  fi
fi

report
[ "$SIGN_IN_FAILED" = 0 ] || explain_credentials
exit "$STATUS"
