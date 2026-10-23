#!/bin/sh
# Download the pinned CEF macOS arm64 distribution to `Frameworks/cef`. Copy the wrapper sources and headers
# into the CEFBridge target's `wrapper_src` and `cefroot` directories, which git ignores. Run once per checkout and again after changing `CEF_VERSION`.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CEF_VERSION="156.0.7+g47dbc1d+chromium-156.0.8078.17"
CEF_SHA1="b7520ed38685059e02a76c9039632c07a8925ce0"
NAME="cef_binary_${CEF_VERSION}_macosarm64.tar.bz2"
DOWNLOADS="$ROOT/Frameworks/cef-download"
CEF="$ROOT/Frameworks/cef"
BRIDGE="$ROOT/Packages/ARCHKit/Sources/CEFBridge"

mkdir -p "$DOWNLOADS"
if [ ! -f "$DOWNLOADS/$NAME" ]; then
  ENCODED="$(printf '%s' "$NAME" | sed 's/+/%2B/g')"
  curl -sL --fail --retry 3 -o "$DOWNLOADS/$NAME" "https://cef-builds.spotifycdn.com/$ENCODED"
fi
ACTUAL="$(shasum -a 1 "$DOWNLOADS/$NAME" | awk '{print $1}')"
[ "$ACTUAL" = "$CEF_SHA1" ] || { echo "checksum mismatch for $NAME: $ACTUAL" >&2; exit 1; }

rm -rf "$CEF"
mkdir -p "$CEF"
tar xjf "$DOWNLOADS/$NAME" -C "$CEF" --strip-components=1

rm -rf "$BRIDGE/wrapper_src" "$BRIDGE/cefroot"
cp -R "$CEF/libcef_dll" "$BRIDGE/wrapper_src"
rm -f "$BRIDGE/wrapper_src/CMakeLists.txt" "$BRIDGE/wrapper_src/BUILD.bazel"
mkdir -p "$BRIDGE/cefroot"
cp -R "$CEF/include" "$BRIDGE/cefroot/include"
# Copy headers only. A source symlink would make Swift Package Manager find the sources twice and omit them.
rsync -a --include='*/' --include='*.h' --exclude='*' "$BRIDGE/wrapper_src/" "$BRIDGE/cefroot/libcef_dll/"
echo "CEF $CEF_VERSION ready in $CEF and $BRIDGE"
