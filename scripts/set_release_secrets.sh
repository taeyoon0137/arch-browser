#!/bin/sh
# Set the repository secrets that `.github/workflows/release.yml` reads (`docs/updates.md`, Release pipeline), with the GitHub CLI, from this Mac's Keychain and the files the maintainer downloaded. No value is printed, and the temporary files are deleted on exit.
# Usage: scripts/set_release_secrets.sh
# - Developer ID: exports the one Developer ID Application identity in the Keychain, with a new random password, as `ARCH_DEVELOPER_ID_P12` and `ARCH_DEVELOPER_ID_P12_PASSWORD`. macOS asks once for the login keychain password to allow the export.
# - Provisioning profile: the newest unexpired Developer ID profile for `xyz.taeyoon.arch` that lists that certificate, as `ARCH_PROVISIONING_PROFILE`; `scripts/provision_app.sh` gets one.
# - Sparkle: exports the private key from `ARCH_SPARKLE_KEY_FILE` or the Keychain account `ARCH_SPARKLE_KEY_ACCOUNT` (environment or `.release.env`) as `ARCH_SPARKLE_PRIVATE_KEY`.
# - Asks for the App Store Connect API key file, its key ID, and the issuer ID (`ARCH_NOTARY_*`), and for the engine token (`ARCH_CHROMIUM_TOKEN`), unless `ARCH_NOTARY_KEY_PATH`, `ARCH_NOTARY_KEY_ID`, `ARCH_NOTARY_ISSUER`, or `ARCH_CHROMIUM_TOKEN` is set. An empty answer skips that secret.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="taeyoon0137/arch-browser"
[ -f "$ROOT/.release.env" ] && . "$ROOT/.release.env"
fail() { echo "$1" >&2; exit 1; }
command -v gh >/dev/null || fail "the GitHub CLI (gh) is not installed"
gh auth status >/dev/null 2>&1 || fail "gh is not signed in; run gh auth login"
TEMP="$(mktemp -d)"
chmod 700 "$TEMP"
trap 'rm -rf "$TEMP"' EXIT INT TERM
set_secret() { gh secret set "$1" --repo "$REPO" >/dev/null && echo "set $1"; }

# The Developer ID Application identity. `security export` writes every identity in the Keychain, so the certificate and its key are picked out by their shared local key ID and packed again on their own. The system's LibreSSL writes the older encryption that `security import` reads.
echo "Developer ID Application: exporting; allow the export when macOS asks"
COUNT="$(security find-identity -v -p codesigning | grep -c '"Developer ID Application' || true)"
[ "$COUNT" = 1 ] || fail "the Keychain has $COUNT valid Developer ID Application identities, and one is needed; docs/updates.md, Release pipeline, says how to create it"
EXPORT_PASSWORD="$(/usr/bin/openssl rand -hex 24)"
security export -t identities -f pkcs12 -P "$EXPORT_PASSWORD" -o "$TEMP/all.p12" >/dev/null
/usr/bin/openssl pkcs12 -in "$TEMP/all.p12" -nodes -passin "pass:$EXPORT_PASSWORD" -out "$TEMP/all.pem" 2>/dev/null
python3 -I - "$TEMP/all.pem" "$TEMP/cert.pem" "$TEMP/key.pem" <<'PY' || fail "the export holds no Developer ID Application certificate with its private key"
import re, subprocess, sys
text = open(sys.argv[1]).read()
blocks = re.findall(r"(Bag Attributes.*?-----END [A-Z ]+-----)", text, re.S)
def key_id(block):
    match = re.search(r"localKeyID: ([0-9A-F ]+)", block)
    return match.group(1).strip() if match else None
certs, keys = {}, {}
for block in blocks:
    pem = block[block.index("-----BEGIN"):]
    if "CERTIFICATE-----" in pem:
        subject = subprocess.run(["/usr/bin/openssl", "x509", "-noout", "-subject"], input=pem, capture_output=True, text=True).stdout
        if "CN=Developer ID Application" in subject or "CN = Developer ID Application" in subject:
            certs[key_id(block)] = pem
    elif "PRIVATE KEY-----" in pem:
        keys[key_id(block)] = pem
matches = [k for k in certs if k and k in keys]
if len(matches) != 1:
    sys.exit(1)
open(sys.argv[2], "w").write(certs[matches[0]])
open(sys.argv[3], "w").write(keys[matches[0]])
PY
P12_PASSWORD="$(/usr/bin/openssl rand -hex 24)"
/usr/bin/openssl pkcs12 -export -in "$TEMP/cert.pem" -inkey "$TEMP/key.pem" -passout "pass:$P12_PASSWORD" -out "$TEMP/identity.p12" 2>/dev/null
rm -f "$TEMP/all.p12" "$TEMP/all.pem" "$TEMP/key.pem"
base64 -i "$TEMP/identity.p12" | set_secret ARCH_DEVELOPER_ID_P12
printf '%s' "$P12_PASSWORD" | set_secret ARCH_DEVELOPER_ID_P12_PASSWORD
rm -f "$TEMP/identity.p12"

# The Developer ID provisioning profile that lists the exported certificate.
CERT_SHA="$(/usr/bin/openssl x509 -in "$TEMP/cert.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')"
PROFILE="$(python3 -I - "$CERT_SHA" "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" <<'PY'
import datetime, glob, hashlib, plistlib, subprocess, sys
sha, folder = sys.argv[1].upper(), sys.argv[2]
now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
best = None
for path in glob.glob(folder + "/*.provisionprofile"):
    try:
        profile = plistlib.loads(subprocess.run(["security", "cms", "-D", "-i", path], capture_output=True).stdout)
    except Exception:
        continue
    granted = profile.get("Entitlements", {})
    certificates = {hashlib.sha1(c).hexdigest().upper() for c in profile.get("DeveloperCertificates", [])}
    if (profile.get("ProvisionsAllDevices") and granted.get("com.apple.application-identifier", "").endswith(".xyz.taeyoon.arch")
            and "OSX" in profile.get("Platform", []) and profile.get("ExpirationDate", now) > now and sha in certificates):
        if best is None or profile.get("CreationDate", now) > best[0]:
            best = (profile.get("CreationDate", now), path)
print(best[1] if best else "")
PY
)"
if [ -n "$PROFILE" ]; then
  base64 -i "$PROFILE" | set_secret ARCH_PROVISIONING_PROFILE
else
  echo "skipped ARCH_PROVISIONING_PROFILE: no Developer ID profile for xyz.taeyoon.arch lists the certificate; run scripts/provision_app.sh, then this script again" >&2
fi

# The Sparkle private key.
SPARKLE_TOOLS="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
if [ -n "${ARCH_SPARKLE_KEY_FILE:-}" ] && [ -f "$ARCH_SPARKLE_KEY_FILE" ]; then
  set_secret ARCH_SPARKLE_PRIVATE_KEY < "$ARCH_SPARKLE_KEY_FILE"
elif [ -n "${ARCH_SPARKLE_KEY_ACCOUNT:-}" ]; then
  [ -x "$SPARKLE_TOOLS/generate_keys" ] || fail "missing Sparkle's tools in $SPARKLE_TOOLS; run swift package resolve first"
  "$SPARKLE_TOOLS/generate_keys" --account "$ARCH_SPARKLE_KEY_ACCOUNT" -x "$TEMP/sparkle.key" >/dev/null
  set_secret ARCH_SPARKLE_PRIVATE_KEY < "$TEMP/sparkle.key"
  rm -f "$TEMP/sparkle.key"
else
  echo "skipped ARCH_SPARKLE_PRIVATE_KEY: set ARCH_SPARKLE_KEY_FILE or ARCH_SPARKLE_KEY_ACCOUNT, in the environment or in .release.env" >&2
fi

# The App Store Connect API key for notarization.
ask() {
  # Arguments: `$1` the prompt, `$2` 1 to hide the answer. Reads from the terminal.
  printf '%s: ' "$1" > /dev/tty
  if [ "$2" = 1 ]; then stty -echo < /dev/tty; fi
  IFS= read -r answer < /dev/tty || answer=""
  if [ "$2" = 1 ]; then stty echo < /dev/tty; printf '\n' > /dev/tty; fi
  printf '%s' "$answer"
}
KEY_PATH="${ARCH_NOTARY_KEY_PATH:-$(ask "App Store Connect API key file (.p8), or empty to skip" 0)}"
if [ -n "$KEY_PATH" ]; then
  # A file dragged into Terminal arrives with escaped spaces and a trailing space; a typed path may start with ~ or carry quotes.
  KEY_PATH="$(printf '%s' "$KEY_PATH" | sed -e 's/ *$//' -e "s/^['\"]//" -e "s/['\"]\$//" -e 's/\\\(.\)/\1/g' -e "s|^~|$HOME|")"
  [ -f "$KEY_PATH" ] || fail "no file at the given path"
  grep -q 'BEGIN PRIVATE KEY' "$KEY_PATH" || fail "the file is not an App Store Connect API key"
  KEY_ID="${ARCH_NOTARY_KEY_ID:-$(ask "Key ID" 0)}"
  ISSUER="${ARCH_NOTARY_ISSUER:-$(ask "Issuer ID" 0)}"
  [ -n "$KEY_ID" ] && [ -n "$ISSUER" ] || fail "the key ID and the issuer ID are both needed"
  set_secret ARCH_NOTARY_KEY < "$KEY_PATH"
  printf '%s' "$KEY_ID" | set_secret ARCH_NOTARY_KEY_ID
  printf '%s' "$ISSUER" | set_secret ARCH_NOTARY_ISSUER
else
  echo "skipped ARCH_NOTARY_KEY, ARCH_NOTARY_KEY_ID, ARCH_NOTARY_ISSUER" >&2
fi

# The read-only token for the engine releases.
TOKEN="${ARCH_CHROMIUM_TOKEN:-$(ask "Fine-grained token for taeyoon0137/arch-chromium (hidden), or empty to skip" 1)}"
if [ -n "$TOKEN" ]; then
  GH_TOKEN="$TOKEN" gh release view --repo taeyoon0137/arch-chromium >/dev/null 2>&1 || fail "the token cannot read taeyoon0137/arch-chromium's releases; give it Contents read access to that repository"
  printf '%s' "$TOKEN" | set_secret ARCH_CHROMIUM_TOKEN
else
  echo "skipped ARCH_CHROMIUM_TOKEN" >&2
fi

echo "secrets in $REPO:"
gh secret list --repo "$REPO"
