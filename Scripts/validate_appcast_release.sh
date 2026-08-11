#!/bin/bash

set -euo pipefail

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

readonly repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly release_dir="${1:-}"
readonly release_tag="${2:-}"
readonly release_body="${3:-}"
readonly info_plist="${4:-$repo_root/Xcodes/Resources/Info.plist}"
readonly verifier="${SPARKLE_SIGNATURE_VERIFIER:-}"

[[ -n "$release_dir" && -n "$release_tag" ]] || fail "release directory and tag are required"
[[ -f "$release_body" && ! -L "$release_body" ]] || fail "release body must be a regular file"
[[ -f "$info_plist" && ! -L "$info_plist" ]] || fail "trusted Info.plist must be a regular file"
[[ -n "$verifier" && -x "$verifier" && ! -L "$verifier" ]] || fail "compiled Sparkle verifier is required"

bash "$repo_root/Scripts/validate_release_artifacts.sh" "$release_dir" "$release_tag" >/dev/null

expected_signature="$(mktemp "${TMPDIR:-/tmp}/xcodes-body-signature.XXXXXX")"
readonly expected_signature
cleanup() {
    rm -f -- "$expected_signature"
}
trap cleanup EXIT

ruby "$repo_root/Scripts/extract_sparkle_signature.rb" "$release_body" > "$expected_signature"
cmp -s -- "$expected_signature" "$release_dir/sparkle-signature.txt" || fail "release body signature does not match signature asset"
"$verifier" "$release_dir/Xcodes.zip" "$release_dir/sparkle-signature.txt" "$info_plist" || fail "released ZIP failed trusted Sparkle signature verification"

printf 'Verified downloaded release bytes for %s.\n' "$release_tag"
