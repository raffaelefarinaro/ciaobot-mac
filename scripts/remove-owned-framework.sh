#!/bin/sh
# Remove the Sparkle framework from this checkout's own .build/Ciaobot.app.
#
# usage: scripts/remove-owned-framework.sh
#
# The repository root is derived from this script's location, never supplied
# by a caller. The build re-creates Ciaobot.app on every run, so an existing
# embedded framework has to be replaced. Recursively deleting through a
# symlinked Contents/Frameworks (or a symlinked .build, app or Contents) would
# delete outside the build output, so every component of the owned path is
# checked first.
#
# Ownership evidence: install-sparkle-framework.sh writes
# .build/.ciaobot-sparkle-owned beside the app only after it created this
# specific framework. A correctly shaped directory without that marker is
# refused. The marker is not a security boundary: a process that can write the
# build output can forge it, and these filesystem checks are not atomic against
# a concurrent writer. It distinguishes build-owned output from an arbitrary
# directory, which is what this replacement step needs.
set -eu

die() {
    printf 'remove-owned-framework: %s\n' "$1" >&2
    exit 1
}

marker_contents='ciaobot-build-owned-sparkle-framework-v1'

[ $# -eq 0 ] || {
    printf 'usage: %s\n' "$0" >&2
    exit 2
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd -P)
bundle=$repo_root/.build/Ciaobot.app
frameworks=$bundle/Contents/Frameworks
framework=$frameworks/Sparkle.framework
marker=$(dirname -- "$bundle")/.ciaobot-sparkle-owned

# Only the exact build-owned path is removable.
current=$repo_root
for component in .build Ciaobot.app Contents; do
    next=$current/$component
    [ -L "$next" ] && die "refusing symlinked path component: $next"
    [ -d "$next" ] || die "missing owned path component: $next"
    current=$next
done
[ -L "$frameworks" ] && die "refusing symlinked path component: $frameworks"
[ "$frameworks" = "$bundle/Contents/Frameworks" ] \
    || die "refusing framework outside the owned Frameworks directory: $frameworks"

validate_marker() {
    [ -f "$marker" ] \
        || die "refusing to remove unowned framework: missing ownership marker $marker"
    [ -L "$marker" ] && die "refusing symlinked ownership marker: $marker"
    contents=$(cat "$marker") || die "cannot read ownership marker: $marker"
    [ "$contents" = "$marker_contents" ] \
        || die "refusing to remove framework: invalid ownership marker"
}

remove_stale_marker() {
    if [ -e "$marker" ] || [ -L "$marker" ]; then
        validate_marker
        rm -f "$marker"
        [ ! -e "$marker" ] && [ ! -L "$marker" ] \
            || die "failed to remove stale ownership marker: $marker"
    fi
}

# A stale marker without a framework is cleaned up so the next install can
# create fresh evidence. Nothing else beside the app or in Frameworks is
# touched.
if [ ! -e "$frameworks" ] && [ ! -L "$frameworks" ]; then
    remove_stale_marker
    printf 'No owned Sparkle framework to remove\n'
    exit 0
fi
[ -d "$frameworks" ] || die "unexpected non-directory at $frameworks"

if [ ! -e "$framework" ] && [ ! -L "$framework" ]; then
    remove_stale_marker
    printf 'No owned Sparkle framework to remove\n'
    exit 0
fi
[ -L "$framework" ] && die "refusing symlinked framework path: $framework"
[ -d "$framework" ] || die "unexpected non-directory at $framework"

# The marker must be checked before any removal: a correctly shaped directory
# this build did not create has no evidence and is left untouched.
validate_marker

# Evidence before removal: the fully resolved path must still be the literal
# owned path. A symlinked ancestor would resolve somewhere else even if the
# component checks above had missed it.
physical=$(CDPATH= cd -- "$framework" && pwd -P) \
    || die "cannot resolve $framework"
[ "$physical" = "$framework" ] || die "framework resolves outside its owned path: $physical"

printf 'Removing owned framework: %s\n' "$framework"
rm -rf "$framework"
[ ! -e "$framework" ] && [ ! -L "$framework" ] \
    || die "failed to remove $framework"
rm -f "$marker"
[ ! -e "$marker" ] && [ ! -L "$marker" ] \
    || die "failed to remove ownership marker: $marker"
