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

readonly derived_data="$test_root/DerivedData"
readonly checkouts="$derived_data/SourcePackages/checkouts"
readonly fixture="$checkouts/FixtureDependency"
readonly output="$test_root/Licenses.rtf"
readonly normal_build_dir="$derived_data/Build/Products"
readonly archive_build_dir="$derived_data/Build/Intermediates.noindex/ArchiveIntermediates/Xcodes/BuildProductsPath"
mkdir -p "$fixture" "$normal_build_dir" "$archive_build_dir"
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

for build_dir in "$normal_build_dir" "$archive_build_dir"; do
    build_output="$test_root/$(basename "$build_dir").rtf"
    xcrun -sdk macosx swift run \
        --package-path "$repo_root/Xcodes/AcknowledgementsGenerator" \
        --scratch-path "$test_root/build" \
        AcknowledgementsGenerator \
        -p "$repo_root/Xcodes.xcodeproj" \
        -o "$build_output" \
        -b "$build_dir"
    grep -aFq 'FixtureDependency' "$build_output" \
        || fail "Build-directory checkout resolution missed dependency for $build_dir"
done

if xcrun -sdk macosx swift run \
    --package-path "$repo_root/Xcodes/AcknowledgementsGenerator" \
    --scratch-path "$test_root/build" \
    AcknowledgementsGenerator \
    -p "$repo_root/Xcodes.xcodeproj" \
    -o "$test_root/missing-build.rtf" \
    -b "$test_root/missing/Build/Products" >/dev/null 2>&1; then
    fail "Build directory without ancestor checkouts was accepted"
fi

grep -Fq -- "-b \\\"\${BUILD_DIR}\\\"" "$repo_root/Xcodes.xcodeproj/project.pbxproj" \
    || fail "Xcode build phase does not pass BUILD_DIR"

printf 'Acknowledgements generator contracts passed\n'
