#!/bin/bash

set -euo pipefail

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

readonly release_dir="${1:-}"
readonly release_tag="${2:-}"

[[ "$release_tag" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)b(0|[1-9][0-9]*)$ ]] || fail "release tag must match vX.Y.ZbN exactly"
readonly release_version="${BASH_REMATCH[1]}"
readonly release_build="${BASH_REMATCH[2]}"
[[ -n "$release_dir" && -d "$release_dir" && ! -L "$release_dir" ]] || fail "release directory must be a real directory"
[[ "${release_dir%/}" == */"$release_tag" ]] || fail "Release directory name must equal release tag"

readonly zip_file="$release_dir/Xcodes.zip"
readonly checksum_file="$release_dir/Xcodes.zip.sha256"
readonly signature_file="$release_dir/sparkle-signature.txt"
readonly manifest_file="$release_dir/release-manifest.txt"

for file in "$zip_file" "$checksum_file" "$signature_file" "$manifest_file"; do
    [[ -f "$file" && ! -L "$file" && -s "$file" ]] || fail "Release artifact is not a regular file: ${file##*/}"
done

entry_count="$(find "$release_dir" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d '[:space:]')"
readonly entry_count
regular_count="$(find "$release_dir" -mindepth 1 -maxdepth 1 -type f -print | wc -l | tr -d '[:space:]')"
readonly regular_count
[[ "$entry_count" == 4 && "$regular_count" == 4 ]] || fail "Release directory must contain exactly four regular files"

if command -v shasum >/dev/null 2>&1; then
    (cd "$release_dir" && shasum -a 256 -c Xcodes.zip.sha256 >/dev/null 2>&1) || fail "ZIP checksum validation failed"
elif command -v sha256sum >/dev/null 2>&1; then
    (cd "$release_dir" && sha256sum -c Xcodes.zip.sha256 >/dev/null 2>&1) || fail "ZIP checksum validation failed"
else
    fail "SHA-256 validation tool is unavailable"
fi
unzip -tq "$zip_file" >/dev/null 2>&1 || fail "Release ZIP is invalid"

signature_line_count="$(wc -l < "$signature_file" | tr -d '[:space:]')"
readonly signature_line_count
sparkle_signature=""
sparkle_signature="$(<"$signature_file")"
readonly sparkle_signature
[[ "$signature_line_count" == 1 && "$sparkle_signature" =~ ^[A-Za-z0-9+/]{86}==$ ]] || fail "Sparkle signature is invalid"

manifest_line_count="$(wc -l < "$manifest_file" | tr -d '[:space:]')"
readonly manifest_line_count
[[ "$manifest_line_count" == 10 ]] || fail "Release manifest must contain exactly ten fields"

require_manifest_line() {
    local expected="$1"
    local message="$2"
    local count

    count="$(grep -Fxc -- "$expected" "$manifest_file" || true)"
    [[ "$count" == 1 ]] || fail "$message"
}

require_manifest_line "tag=$release_tag" "Manifest release tag is missing or duplicated"
require_manifest_line "version=$release_version" "Manifest marketing version is missing or duplicated"
require_manifest_line "build=$release_build" "Manifest build number is missing or duplicated"
require_manifest_line "bundle_id=dev.jacobcx.Xcodes" "Manifest app identity is missing or duplicated"
require_manifest_line "helper_bundle_id=dev.jacobcx.Xcodes.Helper" "Manifest helper identity is missing or duplicated"
require_manifest_line "team_id=K2648T24P4" "Manifest signing team is missing or duplicated"
require_manifest_line "archive=Xcodes.zip" "Manifest archive name is missing or duplicated"
require_manifest_line "sparkle_ed_signature=$sparkle_signature" "Manifest Sparkle signature does not match"

notarization_count="$(grep -Ec '^notarization_id=[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$' "$manifest_file" || true)"
readonly notarization_count
[[ "$notarization_count" == 1 ]] || fail "Manifest notarization identifier is missing or invalid"

expected_checksum=""
expected_checksum="$(awk 'NR == 1 && NF == 2 && $2 == "Xcodes.zip" { print $1 }' "$checksum_file")"
readonly expected_checksum
[[ "$expected_checksum" =~ ^[A-Fa-f0-9]{64}$ ]] || fail "Checksum file is malformed"
require_manifest_line "sha256=$expected_checksum" "Manifest checksum does not match"

printf 'Release artifact contract passed for %s.\n' "$release_tag"
