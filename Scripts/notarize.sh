#!/bin/bash

set -euo pipefail

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_absolute_file() {
    local name="$1"
    local path="$2"

    [[ "$path" == /* ]] || fail "$name must be an absolute path"
    [[ -s "$path" ]] || fail "$name does not exist or is empty: $path"
}

readonly archive_path="${1:-}"
readonly notary_key_id="${NOTARY_KEY_ID:-}"
readonly notary_issuer_id="${NOTARY_ISSUER_ID:-}"
readonly notary_key_path="${NOTARY_KEY_PATH:-}"
readonly xcrun_tool="${XCRUN_TOOL:-/usr/bin/xcrun}"
readonly plutil_tool="${PLUTIL_TOOL:-/usr/bin/plutil}"

[[ -n "$archive_path" ]] || fail "usage: notarize.sh /absolute/path/to/archive.zip"
require_absolute_file "archive" "$archive_path"
[[ -n "$notary_key_id" ]] || fail "NOTARY_KEY_ID is required"
[[ -n "$notary_issuer_id" ]] || fail "NOTARY_ISSUER_ID is required"
[[ "$notary_key_id" =~ ^[A-Za-z0-9]{10,}$ ]] || fail "NOTARY_KEY_ID must be at least 10 alphanumeric characters"
[[ "$notary_issuer_id" =~ ^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$ ]] || fail "NOTARY_ISSUER_ID must be a UUID"
require_absolute_file "NOTARY_KEY_PATH" "$notary_key_path"
[[ "$xcrun_tool" == /* && -x "$xcrun_tool" ]] || fail "XCRUN_TOOL must be an absolute executable path"
[[ "$plutil_tool" == /* && -x "$plutil_tool" ]] || fail "PLUTIL_TOOL must be an absolute executable path"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/xcodes-notary.XXXXXX")"
readonly work_dir
cleanup() {
    case "$work_dir" in
        "${TMPDIR:-/tmp}"/xcodes-notary.*|/private"${TMPDIR:-/tmp}"/xcodes-notary.*)
            rm -rf -- "$work_dir"
            ;;
        *)
            printf 'warning: refused unsafe temporary cleanup: %s\n' "$work_dir" >&2
            ;;
    esac
}
trap cleanup EXIT

readonly result_json="$work_dir/result.json"
"$xcrun_tool" notarytool submit "$archive_path" \
    --key "$notary_key_path" \
    --key-id "$notary_key_id" \
    --issuer "$notary_issuer_id" \
    --wait \
    --output-format json > "$result_json" || fail "notarytool submission failed"

notary_status="$("$plutil_tool" -extract status raw "$result_json" 2>/dev/null || true)"
readonly notary_status
[[ "$notary_status" == "Accepted" ]] || fail "notarization status was '${notary_status:-missing}', expected 'Accepted'"

submission_id="$("$plutil_tool" -extract id raw "$result_json" 2>/dev/null || true)"
readonly submission_id
[[ "$submission_id" =~ ^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$ ]] || \
    fail "notarization response id must be a UUID"
printf '%s\n' "$submission_id"
