#!/bin/sh
# Remove the Sparkle framework from the build's own .build/Ciaobot.app.
#
# usage: scripts/remove-owned-framework.sh REPO_ROOT BUNDLE
#
# The build re-creates Ciaobot.app on every run, so an existing embedded
# framework has to be replaced. Recursively deleting through a symlinked
# Contents/Frameworks (or a symlinked .build, app, Contents or framework)
# would delete or write outside the build output, so every component of the
# exact owned path is checked first. Anything unexpected refuses the removal.
# No other file is touched; an absent framework is not an error.
set -eu

die() {
    printf 'remove-owned-framework: %s\n' "$1" >&2
    exit 1
}

usage() {
    printf 'usage: %s REPO_ROOT BUNDLE\n' "$0" >&2
    exit 2
}

[ $# -eq 2 ] || usage
repo_root=$1
bundle=$2
[ -n "$repo_root" ] && [ -n "$bundle" ] || usage
repo_root=${repo_root%/}
bundle=${bundle%/}
[ -n "$repo_root" ] && [ -n "$bundle" ] || usage

[ -d "$repo_root" ] || die "no repository at $repo_root"
repo_root=$(CDPATH= cd -- "$repo_root" && pwd -P)

# Only the path this build owns is removable. This also means a caller cannot
# aim the recursive delete at an arbitrary directory.
expected="$repo_root/.build/Ciaobot.app"
[ "$bundle" = "$expected" ] || die "refusing unexpected bundle path: $bundle (expected $expected)"

current=$repo_root
for component in .build Ciaobot.app Contents Frameworks Sparkle.framework; do
    next=$current/$component
    [ -L "$next" ] && die "refusing symlinked path component: $next"
    current=$next
    case $component in
        .build|Ciaobot.app|Contents)
            [ -d "$current" ] || die "missing owned path component: $current"
            ;;
        Frameworks|Sparkle.framework)
            if [ ! -e "$current" ]; then
                printf 'No owned Sparkle framework to remove\n'
                exit 0
            fi
            [ -d "$current" ] || die "unexpected non-directory at $current"
            ;;
    esac
done

framework=$current
frameworks=$repo_root/.build/Ciaobot.app/Contents/Frameworks
[ "$framework" = "$frameworks/Sparkle.framework" ] \
    || die "refusing framework outside the owned Frameworks directory: $framework"

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
