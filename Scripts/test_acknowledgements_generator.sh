#!/bin/bash

set -euo pipefail

repo_root=""
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly repo_root
test_root=""
test_root="$(mktemp -d "${TMPDIR:-/tmp}/xcodes-acknowledgements-tests.XXXXXX")"
readonly test_root

cleanup() {
    rm -rf -- "$test_root"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

readonly checkouts="$test_root/checkouts"
readonly fixture="$checkouts/FixtureDependency"
readonly output="$test_root/Licenses.rtf"
mkdir -p "$fixture"
printf 'Fixture licence text\n' > "$fixture/LICENSE"

xcrun -sdk macosx swift run \
    --package-path "$repo_root/Xcodes/AcknowledgementsGenerator" \
    --scratch-path "$test_root/build" \
    AcknowledgementsGenerator \
    -p "$repo_root/Xcodes.xcodeproj" \
    -o "$output" \
    -c "$checkouts"

[[ -s "$output" ]] || fail "Acknowledgements output is missing"
grep -aFq 'FixtureDependency' "$output" || fail "Explicit checkout dependency is missing"
grep -aFq 'Fixture licence text' "$output" || fail "Explicit checkout licence is missing"

if xcrun -sdk macosx swift run \
    --package-path "$repo_root/Xcodes/AcknowledgementsGenerator" \
    --scratch-path "$test_root/build" \
    AcknowledgementsGenerator \
    -p "$repo_root/Xcodes.xcodeproj" \
    -o "$test_root/missing.rtf" \
    -c "$test_root/missing-checkouts" >/dev/null 2>&1; then
    fail "Missing explicit checkouts directory was accepted"
fi

grep -Fq 'BUILD_DIR}/../../SourcePackages/checkouts' "$repo_root/Xcodes.xcodeproj/project.pbxproj" \
    || fail "Xcode build phase does not pass its resolved checkouts directory"

printf 'Acknowledgements generator contracts passed\n'
