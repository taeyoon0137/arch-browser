#!/bin/sh
# Copy the signed `build/Arch.app` into `/Applications` as a real bundle, since native apps such as 1Password accept only a signed browser there that is not reached through a symbolic link (docs/password-managers.md, Installing Arch into /Applications). Run it after scripts/bundle_app.sh. It replaces only an earlier Arch or a link, verifies the copy's signature before it replaces anything, and keeps the earlier bundle until the new one is in place.
# Usage: scripts/install_app.sh
# `ARCH_APP_SOURCE` names another bundle to copy and `ARCH_INSTALL_DIR` another destination folder, for checks. With `ARCH_INSTALL_FUNCTIONS_ONLY=1`, sourcing the script defines `signed_with_team`, `may_replace`, `replace_app`, and `undo_replace` and runs nothing.
# The script never prints the signing identity or the team.
set -eu

ARCH_BUNDLE_IDENTIFIER="xyz.taeyoon.arch"

signed_with_team() {
  # Reads `codesign -dv` output on standard input and succeeds only for a signature with a team: not an ad hoc one, and not none. It prints nothing.
  awk -F= '
    $1 == "Signature" && $2 == "adhoc" { adhoc = 1 }
    $1 == "TeamIdentifier" && $2 != "" && $2 != "not set" { team = 1 }
    END { exit !(team && !adhoc) }
  '
}

may_replace() {
  # Argument: `$1` is the path of `Arch.app` in the destination. Succeeds when nothing is there, when it is a symbolic link, or when it is a bundle with Arch's bundle identifier; otherwise says why it stays and fails.
  if [ -L "$1" ] || [ ! -e "$1" ]; then
    return 0
  fi
  may_replace_identifier="$(plutil -extract CFBundleIdentifier raw -o - "$1/Contents/Info.plist" 2>/dev/null || true)"
  if [ "$may_replace_identifier" = "$ARCH_BUNDLE_IDENTIFIER" ]; then
    return 0
  fi
  if [ -n "$may_replace_identifier" ]; then
    echo "$1 is not Arch (bundle identifier $may_replace_identifier). Move it elsewhere, then run the script again." >&2
  else
    echo "$1 is not Arch. Move it elsewhere, then run the script again." >&2
  fi
  return 1
}

undo_replace() {
  # Argument: `$1` is the path of `Arch.app` in the destination. Deletes the temporary copy of `replace_app` and moves what was at `$1` back. When the copy has already taken `$1`, as when a signal arrives just after the last move, `mv` would put the earlier bundle inside the new one, so it stays aside and the script says where.
  rm -rf "$replace_copy"
  if [ -e "$replace_previous" ] || [ -L "$replace_previous" ]; then
    if [ -e "$1" ] || [ -L "$1" ]; then
      echo "The new copy is at $1, and the earlier copy stays at $replace_previous; delete it by hand." >&2
    else
      mv "$replace_previous" "$1"
    fi
  fi
}

replace_app() {
  # Arguments: `$1` is the bundle to copy and `$2` the path of `Arch.app` in the destination, which `may_replace` allowed. Copies the bundle with `ditto` to a temporary name beside `$2`, checks the copy with `codesign --verify --deep --strict`, moves a link or an earlier bundle at `$2` to a second temporary name, moves the copy into place, and only then deletes what was there. If a step fails, or the script is interrupted, it deletes the copy and moves what was there back.
  replace_destination="$2"
  replace_copy="$(dirname "$2")/.$(basename "$2").installing.$$"
  replace_previous="$(dirname "$2")/.$(basename "$2").previous.$$"
  trap 'undo_replace "$replace_destination"; exit 1' HUP INT TERM
  if replace_output="$(
    ditto "$1" "$replace_copy" 2>&1 &&
      { codesign --verify --deep --strict "$replace_copy" 2>&1 || { echo "The signature of $1 does not verify, so $2 stays as it was. Run scripts/bundle_app.sh again, then run the script again."; false; }; } &&
      { if [ -e "$2" ] || [ -L "$2" ]; then mv "$2" "$replace_previous" 2>&1; fi; } &&
      mv "$replace_copy" "$2" 2>&1
  )"; then
    trap - HUP INT TERM
    # A link goes as a link; an earlier bundle is a copy of an earlier build.
    rm -rf "$replace_previous" || echo "The earlier copy stays at $replace_previous; delete it by hand." >&2
    return 0
  fi
  undo_replace "$2"
  trap - HUP INT TERM
  [ -z "$replace_output" ] || printf '%s\n' "$replace_output" >&2
  case "$replace_output" in
    *"Operation not permitted"*)
      echo "macOS kept the script from changing $2. Allow your terminal app in System Settings ▸ Privacy & Security ▸ App Management, then run the script again." >&2
      ;;
  esac
  return 1
}

if [ "${ARCH_INSTALL_FUNCTIONS_ONLY:-}" = 1 ]; then
  return 0 2>/dev/null || exit 0
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${ARCH_APP_SOURCE:-$ROOT/build/Arch.app}"
DESTINATION="${ARCH_INSTALL_DIR:-/Applications}"
APP="$DESTINATION/Arch.app"

[ -d "$SOURCE" ] || { echo "missing $SOURCE; run scripts/bundle_app.sh first" >&2; exit 1; }
[ -d "$DESTINATION" ] || { echo "missing $DESTINATION" >&2; exit 1; }
# `codesign -dv` writes to standard error, and only `signed_with_team` reads it.
if ! codesign -dv "$SOURCE" 2>&1 | signed_with_team; then
  echo "1Password connects only to signed browsers. Set up a Developer ID Application or Apple Development identity, or set ARCH_SIGN_IDENTITY, then run scripts/bundle_app.sh again." >&2
  exit 1
fi
if ps -axo comm= | grep -Fqx "$APP/Contents/MacOS/Arch"; then
  echo "Arch is running from $APP. Quit it, then run the script again." >&2
  exit 1
fi
may_replace "$APP" || exit 1
replace_app "$SOURCE" "$APP" || exit 1
echo "$APP"
