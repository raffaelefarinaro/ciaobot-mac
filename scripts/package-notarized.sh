#!/bin/sh
# Build and notarize in a fresh directory; never install or modify an app.
#
# Authentication: an App Store Connect API key is preferred, because it needs
# no keychain item and no interactive approval. Set NOTARY_KEY_ID and
# NOTARY_ISSUER (and optionally NOTARY_KEY for the .p8 path; the default is the
# conventional ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8). A
# notarytool keychain profile is still accepted through NOTARY_PROFILE as a
# fallback. Nothing here reads, prints or stores a password.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$root"
: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to a Developer ID Application identity}"

die() {
    printf 'package-notarized: %s\n' "$1" >&2
    exit 1
}

# Resolve one authentication method before doing any work, so a missing
# credential fails before a long build rather than after it.
notary_key=
if [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER:-}" ]; then
    notary_key=${NOTARY_KEY:-$HOME/.appstoreconnect/private_keys/AuthKey_$NOTARY_KEY_ID.p8}
    case $notary_key in
        *.p8) ;;
        *) die "the API key must be a .p8 file: $notary_key" ;;
    esac
    [ -r "$notary_key" ] || die "cannot read the API key at $notary_key"
elif [ -n "${NOTARY_PROFILE:-}" ]; then
    :
else
    die "set NOTARY_KEY_ID and NOTARY_ISSUER (App Store Connect API key), or NOTARY_PROFILE"
fi

submit_for_notarization() {
    zip=$1
    shift
    xcrun notarytool submit "$zip" "$@" --wait --output-format json \
        > "$output/notary-result.json"
}

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
if [ -n "$notary_key" ]; then
    submit_for_notarization "$submission" \
        --key "$notary_key" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER"
else
    submit_for_notarization "$submission" --keychain-profile "$NOTARY_PROFILE"
fi
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
