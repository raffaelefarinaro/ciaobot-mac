#!/bin/sh
# Build and notarize in a fresh directory; never install or modify an app.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$root"
: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to a Developer ID Application identity}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to an existing notarytool keychain profile}"

scripts/build-app.sh
output=$(mktemp -d "${TMPDIR:-/tmp}/ciaobot-notarized.XXXXXX")
bundle=$output/Ciaobot.app
ditto .build/Ciaobot.app "$bundle"
chmod -R u+w "$bundle"
xattr -cr "$bundle" 2>/dev/null || true
# Sign Sparkle's nested helpers inside-out before the app. Signing the app
# first would make the framework's later re-signing invalidate the app seal.
sparkle=$bundle/Contents/Frameworks/Sparkle.framework
if [ -d "$sparkle" ]; then
    scripts/sign-sparkle.sh --distribution "$SIGNING_IDENTITY" "$sparkle"
fi
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$bundle"
codesign --verify --deep --strict --verbose=2 "$bundle"
version=$(plutil -extract CFBundleShortVersionString raw -o - "$bundle/Contents/Info.plist")
case $version in ''|*[!0-9.]*) echo 'Invalid bundle version' >&2; exit 1 ;; esac
submission=$output/submission.zip
ditto -c -k --keepParent "$bundle" "$submission"
xcrun notarytool submit "$submission" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$output/notary-result.json"
python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print("Notarization:", r.get("status"), "submission:", r.get("id")); sys.exit(0 if r.get("status") == "Accepted" else 1)' "$output/notary-result.json"
xcrun stapler staple "$bundle"
xcrun stapler validate "$bundle"
spctl --assess --type execute --verbose=4 "$bundle"
archive=$output/Ciaobot-$version-notarized.zip
ditto -c -k --keepParent "$bundle" "$archive"
mkdir "$output/verify"
ditto -x -k "$archive" "$output/verify"
codesign --verify --deep --strict --verbose=2 "$output/verify/Ciaobot.app"
xcrun stapler validate "$output/verify/Ciaobot.app"
spctl --assess --type execute --verbose=4 "$output/verify/Ciaobot.app"
(cd "$output" && shasum -a 256 "$(basename "$archive")" > "$(basename "$archive").sha256")
printf 'Verified notarized archive: %s\n' "$archive"
