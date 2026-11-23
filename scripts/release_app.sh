#!/bin/sh
# Make an update release of a built Arch.app for Sparkle (`docs/updates.md`): the update archive, its EdDSA signature, and the appcast, in `build/release/<build number>/`. With `ARCH_NOTARY_PROFILE`, a `notarytool` keychain profile, the app is notarized and stapled first. Only `--publish` uploads the archive and the appcast as a GitHub release of the project; without it the script prints what it would upload.
# Usage: scripts/release_app.sh [--publish] [path/to/Arch.app]
# `sign_update` reads the private key from the file at `ARCH_SPARKLE_KEY_FILE`, by default `the key file`, or else from the login Keychain under its account.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="taeyoon0137/arch-browser"
KEY_ACCOUNT=""
# SwiftPM's copy of Sparkle's release has its tools.
TOOLS="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
PUBLISH=0
SOURCE="$ROOT/build/Arch.app"
for arg in "$@"; do
  case "$arg" in
    --publish) PUBLISH=1 ;;
    -*) echo "usage: scripts/release_app.sh [--publish] [path/to/Arch.app]" >&2; exit 2 ;;
    *) SOURCE="$arg" ;;
  esac
done
fail() { echo "$1" >&2; exit 1; }

[ -d "$SOURCE/Contents" ] || fail "missing the app at $SOURCE; run scripts/bundle_app.sh release first"
[ -x "$TOOLS/sign_update" ] || fail "missing Sparkle's tools in $TOOLS; run swift package resolve first"
info() { /usr/libexec/PlistBuddy -c "Print :$1" "$SOURCE/Contents/Info.plist" 2>/dev/null || true; }
BUILD="$(info CFBundleVersion)"
VERSION="$(info CFBundleShortVersionString)"
MIN_MACOS="$(info LSMinimumSystemVersion)"
FEED_URL="$(info SUFeedURL)"
PUBLIC_KEY="$(info SUPublicEDKey)"
COMMIT="$(info ArchBuildCommit)"
[ -n "$BUILD" ] && [ -n "$VERSION" ] && [ -n "$MIN_MACOS" ] || fail "the app's Info.plist lacks its version, build number, or minimum system"
[ -n "$FEED_URL" ] && [ -n "$PUBLIC_KEY" ] || fail "the app has no SUFeedURL or SUPublicEDKey, so it could not check or install an update; docs/updates.md says how to set the public key"
codesign --verify --deep --strict "$SOURCE" || fail "the app's signature does not verify; run scripts/bundle_app.sh again"

TAG="v$VERSION-$BUILD"
OUT="$ROOT/build/release/$BUILD"
NAME="Arch-$VERSION-$BUILD.zip"
ARCHIVE="$OUT/$NAME"
APPCAST="$OUT/appcast.xml"
rm -rf "$OUT"
mkdir -p "$OUT"
# A copy, so that stapling leaves the built app as it is.
APP="$OUT/Arch.app"
ditto "$SOURCE" "$APP"

if [ -n "${ARCH_NOTARY_PROFILE:-}" ]; then
  # Notarization requires the hardened runtime on the app's executables.
  codesign -dv "$APP" 2>&1 | grep -q 'flags=.*runtime' ||
    echo "warning: the app is not signed with the hardened runtime, which notarization requires, so the notary service may reject it" >&2
  ditto -c -k --keepParent "$APP" "$OUT/notarization.zip"
  xcrun notarytool submit "$OUT/notarization.zip" --keychain-profile "$ARCH_NOTARY_PROFILE" --wait
  rm -f "$OUT/notarization.zip"
  # Stapling fails unless the service accepted the app.
  xcrun stapler staple "$APP"
else
  echo "warning: ARCH_NOTARY_PROFILE is not set, so the app is not notarized, and Gatekeeper blocks a copy downloaded from the release page; docs/updates.md says how to make the profile" >&2
fi

ditto -c -k --keepParent "$APP" "$ARCHIVE"
rm -rf "$APP"
ARCH_SPARKLE_KEY_FILE="${ARCH_SPARKLE_KEY_FILE:-}"
if [ -f "$ARCH_SPARKLE_KEY_FILE" ]; then
  SIGNATURE="$("$TOOLS/sign_update" --ed-key-file "$ARCH_SPARKLE_KEY_FILE" -p "$ARCHIVE")"
else
  SIGNATURE="$("$TOOLS/sign_update" --account "$KEY_ACCOUNT" -p "$ARCHIVE")"
fi
[ -n "$SIGNATURE" ] || fail "sign_update gave no signature"
# The app installs only an archive whose signature its own public key checks, so a release signed with another key would never install.
swift - "$PUBLIC_KEY" "$SIGNATURE" "$ARCHIVE" <<'SWIFT' || fail "the archive's signature does not match the app's SUPublicEDKey; sign with the private key of that public key"
import CryptoKit
import Foundation
let arguments = CommandLine.arguments
guard let keyData = Data(base64Encoded: arguments[1]), let signature = Data(base64Encoded: arguments[2]),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
      let archive = try? Data(contentsOf: URL(fileURLWithPath: arguments[3]), options: .mappedIfSafe),
      key.isValidSignature(signature, for: archive) else { exit(1) }
SWIFT
LENGTH="$(stat -f %z "$ARCHIVE")"
PUB_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

# The feed is the latest release's appcast, so each release's appcast lists that release alone. Sparkle compares the build numbers, which grow with each build.
cat > "$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
	<channel>
		<title>Arch</title>
		<link>$FEED_URL</link>
		<item>
			<title>Arch $VERSION ($BUILD)</title>
			<pubDate>$PUB_DATE</pubDate>
			<sparkle:version>$BUILD</sparkle:version>
			<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
			<sparkle:minimumSystemVersion>$MIN_MACOS</sparkle:minimumSystemVersion>
			<enclosure url="https://github.com/$REPO/releases/download/$TAG/$NAME" length="$LENGTH" type="application/octet-stream" sparkle:edSignature="$SIGNATURE"/>
		</item>
	</channel>
</rss>
XML
echo "$ARCHIVE ($LENGTH bytes)"
echo "$APPCAST"

# The release's tag points at the build's commit, which must be on GitHub. A build of uncommitted changes, whose commit ends in +, is not published.
case "$COMMIT" in
  "" | unknown | *+) TARGET="" ;;
  *) TARGET="$(git -C "$ROOT" rev-parse --verify --quiet "$COMMIT^{commit}" || true)" ;;
esac
NOTES="Arch $VERSION, build $BUILD, from commit ${COMMIT:-unknown}."
if [ "$PUBLISH" -eq 1 ]; then
  [ -n "$TARGET" ] || fail "the build's commit (${COMMIT:-unknown}) is not a commit of this repository, or the tree had uncommitted changes; build a committed tree to publish"
  gh release create "$TAG" "$ARCHIVE" "$APPCAST" --repo "$REPO" --target "$TARGET" --title "Arch $VERSION ($BUILD)" --notes "$NOTES" --latest
else
  [ -n "$TARGET" ] || echo "warning: the build's commit (${COMMIT:-unknown}) is not a commit of this repository, or the tree had uncommitted changes, so --publish would stop" >&2
  echo "dry run; with --publish, this uploads the archive and the appcast as the latest release of $REPO:"
  echo "  gh release create $TAG $ARCHIVE $APPCAST --repo $REPO --target ${TARGET:-<commit>} --title \"Arch $VERSION ($BUILD)\" --notes \"$NOTES\" --latest"
fi
