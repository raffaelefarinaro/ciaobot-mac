#!/bin/sh
# Sign Sparkle's nested helpers inside-out, then the framework itself.
#
# usage: scripts/sign-sparkle.sh --adhoc FRAMEWORK
#        scripts/sign-sparkle.sh --distribution IDENTITY FRAMEWORK
#
# Sparkle 2.10.1 ships Installer.xpc, Downloader.xpc, Autoupdate and
# Updater.app inside Sparkle.framework/Versions/B. Signing order follows
# https://sparkle-project.org/documentation/sandboxing/#code-signing: each
# helper first, then the enclosing framework. --deep is never used to sign:
# it would apply the Downloader XPC's entitlement policy to every nested
# binary. The framework itself is never re-laid-out here; callers are expected
# to have copied the resolved artifact with symlinks intact.
set -eu

usage() {
    cat <<'EOF'
usage: scripts/sign-sparkle.sh --adhoc FRAMEWORK
       scripts/sign-sparkle.sh --distribution IDENTITY FRAMEWORK

  --adhoc                 re-sign ad-hoc for local packaging. The app is not
                          hardened, so it can load the framework locally.
  --distribution IDENTITY sign with a Developer ID identity, hardened runtime
                          and a secure timestamp for notarization.

Never installs, launches or contacts the network.
EOF
}

die() {
    printf 'sign-sparkle: %s\n' "$1" >&2
    exit 1
}

[ $# -ge 2 ] || { usage >&2; exit 2; }
mode=$1
shift
case $mode in
    --adhoc)
        [ $# -eq 1 ] || { usage >&2; exit 2; }
        identity=
        ;;
    --distribution)
        [ $# -eq 2 ] || { usage >&2; exit 2; }
        identity=$1
        shift
        [ -n "$identity" ] || die "an empty signing identity is not a distribution identity"
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
framework=$1
[ -d "$framework" ] || die "no framework at $framework"
framework=$(CDPATH= cd -- "$framework" && pwd -P)
case $framework in
    /Applications/*|"${HOME:-/nonexistent}"/Applications/*)
        die "refusing to sign a framework inside an Applications folder: $framework" ;;
esac
[ -d "$framework/Versions/B" ] || die "$framework has no Versions/B"

installer=$framework/Versions/B/XPCServices/Installer.xpc
downloader=$framework/Versions/B/XPCServices/Downloader.xpc
autoupdate=$framework/Versions/B/Autoupdate
updater=$framework/Versions/B/Updater.app
for path in "$installer" "$downloader" "$autoupdate" "$updater"; do
    [ -e "$path" ] || die "missing Sparkle helper: $path"
done

command -v codesign >/dev/null || die "codesign is required"

sign() {
    path=$1
    if [ "$mode" = "--distribution" ]; then
        codesign --force --sign "$identity" --options runtime --timestamp "$path"
    else
        codesign --force --sign - --timestamp=none "$path"
    fi
    codesign --verify --strict --verbose=2 "$path"
}

# Inside-out, exactly the order Sparkle documents. Installer.xpc carries no
# entitlements of its own; Downloader.xpc must keep the ones Sparkle shipped
# with it (an optional sandbox profile can depend on them). Updater.app is
# signed after its executable is already sealed by its own bundle signature.
sign "$installer"
if [ "$mode" = "--distribution" ]; then
    codesign --force --sign "$identity" --options runtime --timestamp \
        --preserve-metadata=entitlements "$downloader"
    codesign --verify --strict --verbose=2 "$downloader"
else
    sign "$downloader"
fi
sign "$autoupdate"
sign "$updater"
sign "$framework"

if [ "$mode" = "--distribution" ]; then
    # A hardened-runtime distribution helper with get-task-allow would let a
    # debugger attach to the installed updater. Refuse that combination
    # instead of shipping it.
    for path in "$installer" "$downloader" "$autoupdate" "$updater" "$framework"; do
        case $path in
            "$installer") label=Installer.xpc ;;
            "$downloader") label=Downloader.xpc ;;
            "$autoupdate") label=Autoupdate ;;
            "$updater") label=Updater.app ;;
            *) label=Sparkle.framework ;;
        esac
        if codesign -d --entitlements - "$path" 2>/dev/null | grep -q 'com.apple.security.get-task-allow'; then
            die "$label has com.apple.security.get-task-allow; refusing a distribution signature"
        fi
        info=$(codesign -d --verbose=4 "$path" 2>&1)
        printf '%s\n' "$info" | grep -q 'flags=.*(.*runtime.*)' \
            || die "$label is not signed with the hardened runtime"
    done
fi

printf 'Signed %s (%s)\n' "$framework" "$mode"
