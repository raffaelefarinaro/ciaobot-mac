#!/bin/sh
# Generate the Sparkle appcast for one already packaged Ciaobot archive.
#
# usage: scripts/make-appcast.sh --archive PATH --download-url PREFIX --output PATH
#
# The archive must be a notarized, Developer ID signed, arm64-only Ciaobot.app
# zipped from the bundle root (scripts/package-notarized.sh produces exactly
# that). This script only reads the archive: it unzips it into a scratch
# directory, verifies identity, version, architecture and notarization, and
# then runs Sparkle's own generate_appcast so archive signatures are produced by
# the pinned tool and never hand-written. The private EdDSA key is read from the
# operator's keychain by generate_appcast; it is never mentioned here.
#
# --download-url is the *prefix* the archives are published under, and it must
# end with "/": generate_appcast appends each archive's file name. Publishing
# the resulting appcast is a separate, deliberate step; this script never
# uploads, installs, launches or contacts the update feed.
#
# CIAOBOT_GENERATE_APPCAST points at an alternate generate_appcast binary. The
# test suite uses it to run a recording double instead of the pinned tool.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$root"

usage() {
    cat <<'EOF'
usage: scripts/make-appcast.sh --archive PATH --download-url PREFIX --output PATH

Generate the Sparkle appcast for one packaged Ciaobot archive.

  --archive PATH        a notarized, Developer ID signed, arm64-only
                        Ciaobot-<version>-<flavour>.zip
  --download-url PREFIX the https URL the archives are published under; must
                        end with "/" because archive names are appended
  --output PATH         the appcast file to write; an existing non-empty file
                        is refused

Reads the archive only: it never publishes, installs, launches or contacts the
update feed. The EdDSA private key stays in the operator's keychain and is read
by Sparkle's own generate_appcast; signatures are never written by hand.
EOF
}

die() {
    printf 'make-appcast: %s\n' "$1" >&2
    exit 1
}

usage_error() {
    usage >&2
    exit 2
}

archive=
download_url=
output=
while [ $# -gt 0 ]; do
    case $1 in
        --archive)
            [ $# -ge 2 ] || usage_error
            archive=$2
            shift 2
            ;;
        --download-url)
            [ $# -ge 2 ] || usage_error
            download_url=$2
            shift 2
            ;;
        --output)
            [ $# -ge 2 ] || usage_error
            output=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'make-appcast: unknown argument: %s\n' "$1" >&2
            usage_error
            ;;
    esac
done

[ -n "$archive" ] || usage_error
[ -n "$download_url" ] || usage_error
[ -n "$output" ] || usage_error

# --- The archive ----------------------------------------------------------

[ -f "$archive" ] && [ ! -L "$archive" ] \
    || die "archive is missing, not a regular file, or a symlink: $archive"
[ -s "$archive" ] || die "archive is empty: $archive"

archive_name=$(basename "$archive")
case $archive_name in
    *.zip) ;;
    *) die "archive must be a .zip produced by scripts/package-notarized.sh: $archive_name" ;;
esac
# Ciaobot-<version>-<flavour>.zip. The version in the name is the version the
# appcast enclosure advertises, so it has to be the version inside the bundle.
archive_version=$(printf '%s' "$archive_name" | sed -n 's/^Ciaobot-\([0-9][0-9.]*\)-.*\.zip$/\1/p')
[ -n "$archive_version" ] \
    || die "archive name must be Ciaobot-<version>-<flavour>.zip, got: $archive_name"

# --- The download URL -----------------------------------------------------

case $download_url in
    https://*) ;;
    *) die "download URL must be https, got: $download_url" ;;
esac
rest=${download_url#https://}
case $rest in
    */*) authority=${rest%%/*} ;;
    *) die "download URL must be a prefix that ends with /: $download_url" ;;
esac
case $authority in
    ''|*@*) die "download URL must not carry credentials: $download_url" ;;
esac
case $download_url in
    *[[:space:]]*|*\?*|*\#*) die "download URL must be a plain path prefix without a query or fragment: $download_url" ;;
    */) ;;
    *) die "download URL must end with / so archive names append cleanly: $download_url" ;;
esac

# --- The output -----------------------------------------------------------

output_dir=$(dirname -- "$output")
[ -d "$output_dir" ] && [ ! -L "$output_dir" ] \
    || die "output directory does not exist: $output_dir"
[ ! -d "$output" ] || die "output is a directory, not an appcast file: $output"
[ ! -L "$output" ] || die "output must not be a symlink: $output"
if [ -e "$output" ] && [ -s "$output" ]; then
    die "refusing a non-empty output: $output"
fi

# --- The pinned tool ------------------------------------------------------

if [ -n "${CIAOBOT_GENERATE_APPCAST:-}" ]; then
    generate_appcast=$CIAOBOT_GENERATE_APPCAST
else
    generate_appcast="$root/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
fi
[ -x "$generate_appcast" ] \
    || die "generate_appcast not found; run: swift package resolve ($generate_appcast)"

# --- Inspect the archive --------------------------------------------------

scratch=$(mktemp -d "${TMPDIR:-/tmp}/ciaobot-appcast.XXXXXX")
cleanup() { rm -rf "$scratch"; }
trap cleanup EXIT INT TERM

ditto -x -k "$archive" "$scratch/unpacked" \
    || die "could not extract the archive: $archive"
app=$scratch/unpacked/Ciaobot.app
[ -d "$app" ] && [ ! -L "$app" ] \
    || die "archive does not contain a real Ciaobot.app directory"
plist=$app/Contents/Info.plist
[ -f "$plist" ] && [ ! -L "$plist" ] || die "archive has no Ciaobot.app/Contents/Info.plist"

identifier=$(plutil -extract CFBundleIdentifier raw -o - "$plist" 2>/dev/null || true)
[ "$identifier" = "local.ciaobot.mac" ] \
    || die "archive is not the Ciaobot app: CFBundleIdentifier is '${identifier:-missing}'"

short_version=$(plutil -extract CFBundleShortVersionString raw -o - "$plist" 2>/dev/null || true)
case $short_version in
    ''|*[!0-9.]*) die "archive has no dotted numeric CFBundleShortVersionString: '${short_version:-missing}'" ;;
esac
[ "$short_version" = "$archive_version" ] \
    || die "version mismatch: archive name says $archive_version, the bundle says $short_version"
build_version=$(plutil -extract CFBundleVersion raw -o - "$plist" 2>/dev/null || true)
case $build_version in
    ''|*[!0-9]*) die "archive has no numeric CFBundleVersion: '${build_version:-missing}'" ;;
esac

executable=$(plutil -extract CFBundleExecutable raw -o - "$plist" 2>/dev/null || true)
[ -n "$executable" ] && [ -f "$app/Contents/MacOS/$executable" ] \
    || die "archive has no Contents/MacOS/${executable:-<CFBundleExecutable>}"
architectures=$(lipo -archs "$app/Contents/MacOS/$executable" 2>/dev/null || true)
[ "$architectures" = "arm64" ] \
    || die "archive must be a thin arm64 build, got: '${architectures:-unknown}'"

# An update the client cannot launch is not an update. The signature has to
# verify inside the archive and the notarization ticket has to be stapled, so
# Sparkle's verification and Gatekeeper agree on the same code.
codesign --verify --deep --strict "$app" \
    || die "archive is not validly signed after unzipping"
xcrun stapler validate "$app" \
    || die "archive is not notarized (no stapled ticket)"
spctl --assess --type execute "$app" \
    || die "Gatekeeper does not accept the archived app"

# --- Generate the appcast -------------------------------------------------

# generate_appcast reads a directory of archives and writes the appcast beside
# them, so stage this one archive under its published name.
stage=$scratch/feed
mkdir "$stage"
cp "$archive" "$stage/$archive_name"
appcast_name=appcast.xml
"$generate_appcast" \
    --download-url-prefix "$download_url" \
    -o "$appcast_name" \
    "$stage" \
    || die "generate_appcast failed"

generated=$stage/$appcast_name
[ -f "$generated" ] && [ -s "$generated" ] \
    || die "generate_appcast did not write $appcast_name"

mv "$generated" "$output"
[ -s "$output" ] || die "appcast output is empty: $output"
printf 'Generated %s\n' "$output"
