#!/bin/bash

set -euo pipefail

readonly repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly test_root="$(mktemp -d "${TMPDIR:-/tmp}/xcodes-sparkle-verifier.XXXXXX")"
readonly verifier="$test_root/verify-sparkle-signature"
readonly generator="$test_root/generate-sparkle-fixture"

cleanup() {
    rm -rf -- "$test_root"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

expect_failure() {
    local expected="$1"
    shift
    local output="$test_root/failure.log"
    if "$@" > "$output" 2>&1; then
        fail "Verifier unexpectedly accepted tampered fixture"
    fi
    grep -Fq -- "$expected" "$output" || { sed -n '1,60p' "$output" >&2; fail "Missing failure: $expected"; }
}

xcrun swiftc -parse-as-library "$repo_root/Scripts/verify_sparkle_signature.swift" -o "$verifier"
xcrun swiftc "$repo_root/Scripts/generate_sparkle_test_fixture.swift" -o "$generator"

make_fixture() {
    local name="$1"
    local root="$test_root/$name"
    local release_dir="$root/v4.0.4b39"
    local checksum
    local signature
    mkdir -p "$release_dir/payload/Xcodes.app"
    printf 'application\n' > "$release_dir/payload/Xcodes.app/content"
    (cd "$release_dir/payload" && /usr/bin/zip -qry "$release_dir/Xcodes.zip" Xcodes.app)
    rm -rf -- "$release_dir/payload"
    "$generator" "$release_dir/Xcodes.zip" "$release_dir/sparkle-signature.txt" "$root/Info.plist" "$root/release-body.txt"
    checksum="$(shasum -a 256 "$release_dir/Xcodes.zip" | awk '{ print $1 }')"
    signature="$(<"$release_dir/sparkle-signature.txt")"
    printf '%s  Xcodes.zip\n' "$checksum" > "$release_dir/Xcodes.zip.sha256"
    printf 'tag=v4.0.4b39\nversion=4.0.4\nbuild=39\nbundle_id=dev.jacobcx.Xcodes\nhelper_bundle_id=dev.jacobcx.Xcodes.Helper\nteam_id=K2648T24P4\nnotarization_id=00000000-0000-0000-0000-000000000000\narchive=Xcodes.zip\nsha256=%s\nsparkle_ed_signature=%s\n' \
        "$checksum" "$signature" > "$release_dir/release-manifest.txt"
    printf '%s\n' "$root"
}

validate_fixture() {
    local root="$1"
    SPARKLE_SIGNATURE_VERIFIER="$verifier" bash "$repo_root/Scripts/validate_appcast_release.sh" \
        "$root/v4.0.4b39" v4.0.4b39 "$root/release-body.txt" "$root/Info.plist"
}

fixture="$(make_fixture valid)"
validate_fixture "$fixture" >/dev/null

fixture="$(make_fixture zip-tamper)"
printf 'tamper\n' >> "$fixture/v4.0.4b39/Xcodes.zip"
expect_failure "ZIP checksum validation failed" validate_fixture "$fixture"

fixture="$(make_fixture checksum-tamper)"
printf '%064d  Xcodes.zip\n' 0 > "$fixture/v4.0.4b39/Xcodes.zip.sha256"
expect_failure "ZIP checksum validation failed" validate_fixture "$fixture"

fixture="$(make_fixture signature-tamper)"
ruby -rbase64 -e 'path = ARGV.fetch(0); bytes = Base64.strict_decode64(File.read(path).strip); bytes.setbyte(0, bytes.getbyte(0) ^ 1); File.write(path, Base64.strict_encode64(bytes) + "\n")' \
    "$fixture/v4.0.4b39/sparkle-signature.txt"
signature="$(<"$fixture/v4.0.4b39/sparkle-signature.txt")"
ruby -e 'path, signature = ARGV; text = File.read(path).sub(/^sparkle_ed_signature=.*$/, "sparkle_ed_signature=#{signature}"); File.write(path, text)' \
    "$fixture/v4.0.4b39/release-manifest.txt" "$signature"
ruby -e 'path, signature = ARGV; text = File.read(path).sub(/sparkle:edSignature=[A-Za-z0-9+\/=]+/, "sparkle:edSignature=#{signature}"); File.write(path, text)' \
    "$fixture/release-body.txt" "$signature"
expect_failure "released ZIP failed trusted Sparkle signature verification" validate_fixture "$fixture"

fixture="$(make_fixture body-mismatch)"
ruby -rbase64 -e 'path = ARGV.fetch(0); text = File.read(path); match = text.match(/sparkle:edSignature=([A-Za-z0-9+\/=]+)/); bytes = Base64.strict_decode64(match[1]); bytes.setbyte(0, bytes.getbyte(0) ^ 1); File.write(path, text.sub(match[1], Base64.strict_encode64(bytes)))' \
    "$fixture/release-body.txt"
expect_failure "release body signature does not match signature asset" validate_fixture "$fixture"

fixture="$(make_fixture public-key-tamper)"
plutil -replace SUPublicEDKey -string AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= "$fixture/Info.plist"
expect_failure "released ZIP failed trusted Sparkle signature verification" validate_fixture "$fixture"

printf 'Sparkle signature verifier contracts passed.\n'
