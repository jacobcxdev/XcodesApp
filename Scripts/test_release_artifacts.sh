#!/bin/bash

set -euo pipefail

repo_root=""
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly repo_root
readonly validator="$repo_root/Scripts/validate_release_artifacts.sh"
test_root=""
test_root="$(mktemp -d "${TMPDIR:-/tmp}/xcodes-artifact-tests.XXXXXX")"
readonly test_root

cleanup() {
    rm -rf -- "$test_root"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

make_fixture() {
    local name="$1"
    local release_dir="$test_root/$name/v4.0.4b39"
    local checksum
    local signature

    mkdir -p "$release_dir/payload/Xcodes.app"
    printf 'application\n' > "$release_dir/payload/Xcodes.app/content"
    (cd "$release_dir/payload" && /usr/bin/zip -qry "$release_dir/Xcodes.zip" Xcodes.app)
    rm -rf -- "$release_dir/payload"
    checksum="$(/usr/bin/shasum -a 256 "$release_dir/Xcodes.zip" | awk '{ print $1 }')"
    signature="$(printf '%086d==' 0 | tr '0' 'A')"
    printf '%s  Xcodes.zip\n' "$checksum" > "$release_dir/Xcodes.zip.sha256"
    printf '%s\n' "$signature" > "$release_dir/sparkle-signature.txt"
    printf 'tag=v4.0.4b39\nversion=4.0.4\nbuild=39\nbundle_id=dev.jacobcx.Xcodes\nhelper_bundle_id=dev.jacobcx.Xcodes.Helper\nteam_id=K2648T24P4\nnotarization_id=00000000-0000-0000-0000-000000000000\narchive=Xcodes.zip\nsha256=%s\nsparkle_ed_signature=%s\n' \
        "$checksum" "$signature" > "$release_dir/release-manifest.txt"
    printf '%s\n' "$release_dir"
}

expect_failure() {
    local expected="$1"
    shift
    local output="$test_root/failure.log"

    if "$@" > "$output" 2>&1; then
        fail "Validator unexpectedly accepted invalid artifact"
    fi
    grep -Fq -- "$expected" "$output" || {
        sed -n '1,80p' "$output" >&2
        fail "Missing failure: $expected"
    }
}

[[ -x "$validator" ]] || fail "Artifact validator is missing or not executable"

fixture="$(make_fixture valid)"
bash "$validator" "$fixture" v4.0.4b39 >/dev/null

fixture="$(make_fixture checksum)"
printf 'tamper\n' >> "$fixture/Xcodes.zip"
expect_failure "ZIP checksum validation failed" bash "$validator" "$fixture" v4.0.4b39

fixture="$(make_fixture tag)"
sed -i '' 's/tag=v4.0.4b39/tag=v4.0.4b40/' "$fixture/release-manifest.txt"
expect_failure "Manifest release tag is missing or duplicated" bash "$validator" "$fixture" v4.0.4b39

fixture="$(make_fixture signature)"
printf '%088d\n' 0 | tr '0' 'B' > "$fixture/sparkle-signature.txt"
expect_failure "Sparkle signature is invalid" bash "$validator" "$fixture" v4.0.4b39

fixture="$(make_fixture manifest-signature)"
sed -i '' 's/sparkle_ed_signature=.*/sparkle_ed_signature=wrong/' "$fixture/release-manifest.txt"
expect_failure "Manifest Sparkle signature does not match" bash "$validator" "$fixture" v4.0.4b39

fixture="$(make_fixture extra)"
printf 'unexpected\n' > "$fixture/debug.log"
expect_failure "Release directory must contain exactly four regular files" bash "$validator" "$fixture" v4.0.4b39

fixture="$(make_fixture symlink)"
rm "$fixture/Xcodes.zip.sha256"
ln -s /etc/hosts "$fixture/Xcodes.zip.sha256"
expect_failure "Release artifact is not a regular file" bash "$validator" "$fixture" v4.0.4b39

fixture="$(make_fixture wrong-directory)"
expect_failure "Release directory name must equal release tag" bash "$validator" "$fixture" v4.0.4b40

printf 'Release artifact contracts passed.\n'
