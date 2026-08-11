#!/bin/bash

set -euo pipefail

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

repo_root=""
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly repo_root
readonly release_dir="${1:-}"
readonly release_tag="${2:-}"
readonly release_body="${3:-}"
readonly info_plist="${4:-$repo_root/Xcodes/Resources/Info.plist}"
readonly verifier="${SPARKLE_SIGNATURE_VERIFIER:-}"
readonly embedded_info_path="Xcodes.app/Contents/Info.plist"

[[ -n "$release_dir" && -n "$release_tag" ]] || fail "release directory and tag are required"
[[ "$release_tag" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)b(0|[1-9][0-9]*)$ ]] || fail "release tag must match vX.Y.ZbN exactly"
readonly release_version="${BASH_REMATCH[1]}"
readonly release_build="${BASH_REMATCH[2]}"
[[ -f "$release_body" && ! -L "$release_body" ]] || fail "release body must be a regular file"
[[ -f "$info_plist" && ! -L "$info_plist" ]] || fail "trusted Info.plist must be a regular file"
[[ -n "$verifier" && -x "$verifier" && ! -L "$verifier" ]] || fail "compiled Sparkle verifier is required"

bash "$repo_root/Scripts/validate_release_artifacts.sh" "$release_dir" "$release_tag" >/dev/null

umask 077
expected_signature=""
embedded_info=""
expected_signature="$(mktemp "${TMPDIR:-/tmp}/xcodes-body-signature.XXXXXX")"
embedded_info="$(mktemp "${TMPDIR:-/tmp}/xcodes-embedded-info.XXXXXX")"
readonly expected_signature
readonly embedded_info
cleanup() {
    rm -f -- "$expected_signature" "$embedded_info"
}
trap cleanup EXIT

ruby "$repo_root/Scripts/inspect_app_archive.rb" "$release_dir/Xcodes.zip" >/dev/null
/usr/bin/unzip -p "$release_dir/Xcodes.zip" "$embedded_info_path" > "$embedded_info" || \
    fail "embedded app Info.plist could not be read"
plutil -lint "$embedded_info" >/dev/null 2>&1 || fail "embedded app Info.plist is invalid"

embedded_version=""
embedded_build=""
embedded_identifier=""
embedded_public_key=""
trusted_public_key=""
embedded_version="$(plutil -extract CFBundleShortVersionString raw -o - "$embedded_info" 2>/dev/null)" || \
    fail "embedded app Info.plist lacks CFBundleShortVersionString"
embedded_build="$(plutil -extract CFBundleVersion raw -o - "$embedded_info" 2>/dev/null)" || \
    fail "embedded app Info.plist lacks CFBundleVersion"
embedded_identifier="$(plutil -extract CFBundleIdentifier raw -o - "$embedded_info" 2>/dev/null)" || \
    fail "embedded app Info.plist lacks CFBundleIdentifier"
embedded_public_key="$(plutil -extract SUPublicEDKey raw -o - "$embedded_info" 2>/dev/null)" || \
    fail "embedded app Info.plist lacks SUPublicEDKey"
trusted_public_key="$(plutil -extract SUPublicEDKey raw -o - "$info_plist" 2>/dev/null)" || \
    fail "trusted Info.plist lacks SUPublicEDKey"
readonly embedded_version embedded_build embedded_identifier embedded_public_key trusted_public_key
[[ "$embedded_version" == "$release_version" ]] || fail "embedded app marketing version does not match release tag"
[[ "$embedded_build" == "$release_build" ]] || fail "embedded app build does not match release tag"
[[ "$embedded_identifier" == "dev.jacobcx.Xcodes" ]] || fail "embedded app identifier does not match maintained fork"
[[ "$embedded_public_key" == "$trusted_public_key" ]] || fail "embedded app Sparkle public key does not match trusted key"

ruby "$repo_root/Scripts/extract_sparkle_signature.rb" "$release_body" > "$expected_signature"
cmp -s -- "$expected_signature" "$release_dir/sparkle-signature.txt" || fail "release body signature does not match signature asset"
"$verifier" "$release_dir/Xcodes.zip" "$release_dir/sparkle-signature.txt" "$info_plist" || fail "released ZIP failed trusted Sparkle signature verification"

printf 'Verified downloaded release bytes for %s.\n' "$release_tag"
