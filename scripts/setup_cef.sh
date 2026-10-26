#!/bin/sh
# Download the pinned CEF macOS arm64 distribution, a release of taeyoon0137/arch-chromium, to `Frameworks/cef` with
# the GitHub CLI, signed in with access to that repository. Copy the wrapper sources and headers into the CEFBridge
# target's `wrapper_src` and `cefroot` directories, which git ignores. Run once per checkout and again after changing
# the pin; a run after an interrupted download, or with a kept archive whose checksum differs from the pin's, downloads
# the archive again. To try a distribution that arch-chromium's arch/build.sh made before it is released, set
# `ARCH_CEF_ARCHIVE` to that archive's path; the pin's checksum does not apply to it.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CEF_RELEASE="arch-8078-5"
CEF_VERSION="156.0.49-arch-8078.3694+gc51d2f8+chromium-156.0.8078.48"
CEF_SHA256="67b963f91d324880fd43c9a15e4cf2231453f3a2f20e5bdf89905d4587792f60"
NAME="cef_binary_${CEF_VERSION}_macosarm64_arch_minimal.tar.bz2"
DOWNLOADS="$ROOT/Frameworks/cef-download"
CEF="$ROOT/Frameworks/cef"
BRIDGE="$ROOT/Packages/ARCHKit/Sources/CEFBridge"

if [ -n "${ARCH_CEF_ARCHIVE:-}" ]; then
  ARCHIVE="$ARCH_CEF_ARCHIVE"
  NAME="$(basename "$ARCHIVE")"
else
  ARCHIVE="$DOWNLOADS/$NAME"
  if [ ! -f "$ARCHIVE" ] || [ "$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')" != "$CEF_SHA256" ]; then
    # Download into a folder of its own and move the archive into place only once its checksum matches, so that an
    # interrupted download is downloaded again on the next run rather than taken for the archive.
    PARTIAL="$DOWNLOADS/partial"
    rm -rf "$PARTIAL" "$ARCHIVE"
    mkdir -p "$PARTIAL"
    gh release download "$CEF_RELEASE" --repo taeyoon0137/arch-chromium --pattern "$NAME" --dir "$PARTIAL"
    ACTUAL="$(shasum -a 256 "$PARTIAL/$NAME" | awk '{print $1}')"
    if [ "$ACTUAL" != "$CEF_SHA256" ]; then
      rm -rf "$PARTIAL"
      echo "checksum mismatch for the downloaded $NAME: $ACTUAL, expected $CEF_SHA256" >&2
      exit 1
    fi
    mv "$PARTIAL/$NAME" "$ARCHIVE"
    rmdir "$PARTIAL"
  fi
fi

rm -rf "$CEF"
mkdir -p "$CEF"
tar xjf "$ARCHIVE" -C "$CEF" --strip-components=1

rm -rf "$BRIDGE/wrapper_src" "$BRIDGE/cefroot"
cp -R "$CEF/libcef_dll" "$BRIDGE/wrapper_src"
rm -f "$BRIDGE/wrapper_src/CMakeLists.txt" "$BRIDGE/wrapper_src/BUILD.bazel"
mkdir -p "$BRIDGE/cefroot"
cp -R "$CEF/include" "$BRIDGE/cefroot/include"
# Copy headers only. A source symlink would make Swift Package Manager find the sources twice and omit them.
rsync -a --include='*/' --include='*.h' --exclude='*' "$BRIDGE/wrapper_src/" "$BRIDGE/cefroot/libcef_dll/"
echo "CEF $NAME ready in $CEF and $BRIDGE"
