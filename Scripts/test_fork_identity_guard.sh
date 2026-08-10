#!/bin/bash

set -euo pipefail

readonly repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly test_root="$(mktemp -d "${TMPDIR:-/tmp}/xcodes-fork-identity-test.XXXXXX")"
readonly fixture_root="$test_root/repo"

cleanup() {
    rm -r -- "$test_root"
}
trap cleanup EXIT

mkdir -p "$fixture_root/Xcodes/Resources" "$fixture_root/Scripts"
cp -R \
    "$repo_root/Xcodes.xcodeproj" \
    "$repo_root/HelperXPCShared" \
    "$repo_root/dev.jacobcx.Xcodes.Helper" \
    "$fixture_root/"
cp \
    "$repo_root/Scripts/check_fork_identity.sh" \
    "$repo_root/Scripts/uninstall_privileged_helper.sh" \
    "$fixture_root/Scripts/"
cp "$repo_root/Xcodes/Resources/Info.plist" "$fixture_root/Xcodes/Resources/Info.plist"

"$fixture_root/Scripts/check_fork_identity.sh" >/dev/null

perl -0pi -e \
    's/PRODUCT_BUNDLE_IDENTIFIER = dev\.jacobcx\.Xcodes;/PRODUCT_BUNDLE_IDENTIFIER = unexpected.example.Xcodes;/' \
    "$fixture_root/Xcodes.xcodeproj/project.pbxproj"

if "$fixture_root/Scripts/check_fork_identity.sh" >/dev/null 2>&1; then
    echo "Identity guard accepted a mutated build configuration" >&2
    exit 1
fi

echo "Fork identity guard mutation test passed"
