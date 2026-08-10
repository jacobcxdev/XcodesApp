#!/bin/bash

set -euo pipefail

# Usage: package_release.sh vX.Y.Z
# Required environment: NOTARY_KEY_ID, NOTARY_ISSUER_ID, NOTARY_KEY_PATH.
# Optional Sparkle input: SPARKLE_PRIVATE_KEY_FILE; otherwise dedicated Keychain account is used.
# Outputs: Product/Xcodes.zip, Product/Xcodes.zip.sha256,
#          Product/sparkle-signature.txt, and Product/release-manifest.txt.

readonly team_id="K2648T24P4"
readonly app_bundle_id="dev.jacobcx.Xcodes"
readonly helper_bundle_id="dev.jacobcx.Xcodes.Helper"
readonly signing_identity="Developer ID Application"
readonly sparkle_keychain_account="${SPARKLE_KEYCHAIN_ACCOUNT:-dev.jacobcx.Xcodes}"

scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly scripts_dir
repository_root="$(cd "$scripts_dir/.." && pwd)"
readonly repository_root
readonly project_path="$repository_root/Xcodes.xcodeproj"
readonly export_options_path="$scripts_dir/export_options.plist"
readonly notarize_script="$scripts_dir/notarize.sh"
readonly generated_licences_path="$repository_root/Xcodes/Resources/Licenses.rtf"
readonly product_dir="$repository_root/Product"
readonly final_zip="$product_dir/Xcodes.zip"
readonly signature_file="$product_dir/sparkle-signature.txt"
readonly checksum_file="$product_dir/Xcodes.zip.sha256"
readonly manifest_file="$product_dir/release-manifest.txt"

readonly git_tool="${GIT_TOOL:-/usr/bin/git}"
readonly xcodebuild_tool="${XCODEBUILD_TOOL:-/usr/bin/xcodebuild}"
readonly security_tool="${SECURITY_TOOL:-/usr/bin/security}"
readonly codesign_tool="${CODESIGN_TOOL:-/usr/bin/codesign}"
readonly plutil_tool="${PLUTIL_TOOL:-/usr/bin/plutil}"
readonly ditto_tool="${DITTO_TOOL:-/usr/bin/ditto}"
readonly xcrun_tool="${XCRUN_TOOL:-/usr/bin/xcrun}"
readonly spctl_tool="${SPCTL_TOOL:-/usr/sbin/spctl}"
readonly shasum_tool="${SHASUM_TOOL:-/usr/bin/shasum}"

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_tool() {
    local name="$1"
    local path="$2"

    [[ "$path" == /* && -x "$path" ]] || fail "$name must be an absolute executable path"
}

require_absolute_file() {
    local name="$1"
    local path="$2"

    [[ "$path" == /* ]] || fail "$name must be an absolute path"
    [[ -s "$path" ]] || fail "$name does not exist or is empty: $path"
}

for tool_spec in \
    "GIT_TOOL:$git_tool" \
    "XCODEBUILD_TOOL:$xcodebuild_tool" \
    "SECURITY_TOOL:$security_tool" \
    "CODESIGN_TOOL:$codesign_tool" \
    "PLUTIL_TOOL:$plutil_tool" \
    "DITTO_TOOL:$ditto_tool" \
    "XCRUN_TOOL:$xcrun_tool" \
    "SPCTL_TOOL:$spctl_tool" \
    "SHASUM_TOOL:$shasum_tool"; do
    require_tool "${tool_spec%%:*}" "${tool_spec#*:}"
done

readonly release_tag="${1:-${RELEASE_TAG:-${GITHUB_REF_NAME:-}}}"
if [[ ! "$release_tag" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
    fail "release tag must match vX.Y.Z exactly"
fi
readonly release_version="${BASH_REMATCH[1]}"

cd "$repository_root"
[[ -z "$("$git_tool" status --porcelain --untracked-files=no)" ]] || fail "tracked working tree must be clean"
"$git_tool" tag --points-at HEAD | grep -Fxq -- "$release_tag" || fail "release tag '$release_tag' must point at HEAD"

build_settings="$("$xcodebuild_tool" \
    -project "$project_path" \
    -scheme Xcodes \
    -configuration Release \
    -showBuildSettings)"
readonly build_settings
project_version="$(printf '%s\n' "$build_settings" | awk -F ' = ' '$1 ~ /^[[:space:]]*MARKETING_VERSION$/ { print $2; exit }')"
readonly project_version
project_build="$(printf '%s\n' "$build_settings" | awk -F ' = ' '$1 ~ /^[[:space:]]*CURRENT_PROJECT_VERSION$/ { print $2; exit }')"
readonly project_build
[[ -n "$project_version" ]] || fail "MARKETING_VERSION was missing from build settings"
[[ -n "$project_build" ]] || fail "CURRENT_PROJECT_VERSION was missing from build settings"
[[ "$release_version" == "$project_version" ]] || fail "tag version '$release_version' does not match MARKETING_VERSION '$project_version'"

readonly notary_key_id="${NOTARY_KEY_ID:-}"
readonly notary_issuer_id="${NOTARY_ISSUER_ID:-}"
readonly notary_key_path="${NOTARY_KEY_PATH:-}"
[[ -n "$notary_key_id" ]] || fail "NOTARY_KEY_ID is required"
[[ -n "$notary_issuer_id" ]] || fail "NOTARY_ISSUER_ID is required"
[[ "$notary_key_id" =~ ^[A-Za-z0-9]{10,}$ ]] || fail "NOTARY_KEY_ID must be at least 10 alphanumeric characters"
[[ "$notary_issuer_id" =~ ^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$ ]] || fail "NOTARY_ISSUER_ID must be a UUID"
require_absolute_file "NOTARY_KEY_PATH" "$notary_key_path"

readonly sparkle_private_key_file="${SPARKLE_PRIVATE_KEY_FILE:-}"
if [[ -n "$sparkle_private_key_file" ]]; then
    require_absolute_file "SPARKLE_PRIVATE_KEY_FILE" "$sparkle_private_key_file"
fi

certificate_identities="$("$security_tool" find-identity -v -p codesigning)"
readonly certificate_identities
printf '%s\n' "$certificate_identities" | grep -Eq "Developer ID Application:.*\\($team_id\\)" || fail "Developer ID Application certificate for team $team_id is missing"

mkdir -p "$product_dir"
[[ -f "$generated_licences_path" ]] || fail "tracked licences file is missing: $generated_licences_path"
for output in "$final_zip" "$signature_file" "$checksum_file" "$manifest_file"; do
    [[ ! -e "$output" ]] || fail "refusing to overwrite existing release output: $output"
done

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/xcodes-release.XXXXXX")"
readonly work_dir
readonly licences_backup="$work_dir/Licenses.rtf"

restore_generated_source() {
    if [[ -f "$licences_backup" ]] && ! /usr/bin/cmp -s "$licences_backup" "$generated_licences_path"; then
        /bin/cp "$licences_backup" "$generated_licences_path"
    fi
}

cleanup() {
    restore_generated_source
    case "$work_dir" in
        "${TMPDIR:-/tmp}"/xcodes-release.*|/private"${TMPDIR:-/tmp}"/xcodes-release.*)
            rm -rf -- "$work_dir"
            ;;
        *)
            printf 'warning: refused unsafe temporary cleanup: %s\n' "$work_dir" >&2
            ;;
    esac
}
trap cleanup EXIT
/bin/cp "$generated_licences_path" "$licences_backup"

readonly derived_data="$work_dir/DerivedData"
readonly archive_path="$work_dir/Xcodes.xcarchive"
readonly export_path="$work_dir/Export"
readonly submission_zip="$work_dir/Xcodes-submission.zip"
readonly release_zip="$work_dir/Xcodes.zip"
readonly signature_report="$work_dir/signature-report.txt"
readonly entitlements_report="$work_dir/entitlements-report.txt"
readonly staged_signature_file="$work_dir/sparkle-signature.txt"
readonly staged_checksum_file="$work_dir/Xcodes.zip.sha256"
readonly staged_manifest_file="$work_dir/release-manifest.txt"

"$xcodebuild_tool" archive \
    -project "$project_path" \
    -scheme Xcodes \
    -configuration Release \
    -archivePath "$archive_path" \
    -derivedDataPath "$derived_data" \
    DEVELOPMENT_TEAM="$team_id" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$signing_identity"

restore_generated_source
[[ -z "$("$git_tool" status --porcelain --untracked-files=no)" ]] || fail "archive modified tracked files unexpectedly"

"$xcodebuild_tool" -exportArchive \
    -archivePath "$archive_path" \
    -exportPath "$export_path" \
    -exportOptionsPlist "$export_options_path"

readonly app_path="$export_path/Xcodes.app"
readonly helper_path="$app_path/Contents/Library/LaunchServices/$helper_bundle_id"
[[ -d "$app_path" ]] || fail "export did not produce Xcodes.app"
[[ -f "$helper_path" ]] || fail "exported app did not contain $helper_bundle_id"

app_version="$("$plutil_tool" -extract CFBundleShortVersionString raw "$app_path/Contents/Info.plist")"
readonly app_version
app_build="$("$plutil_tool" -extract CFBundleVersion raw "$app_path/Contents/Info.plist")"
readonly app_build
exported_app_id="$("$plutil_tool" -extract CFBundleIdentifier raw "$app_path/Contents/Info.plist")"
readonly exported_app_id
[[ "$app_version" == "$release_version" ]] || fail "exported app version '$app_version' does not match tag '$release_version'"
[[ "$app_build" == "$project_build" ]] || fail "exported app build '$app_build' does not match project build '$project_build'"
[[ "$exported_app_id" == "$app_bundle_id" ]] || fail "exported app identifier '$exported_app_id' is not '$app_bundle_id'"

verify_signature() {
    local target_path="$1"
    local expected_identifier="$2"

    "$codesign_tool" --verify --deep --strict --verbose=2 "$target_path" || fail "signature verification failed for $target_path"
    "$codesign_tool" --display --requirements - --verbose=4 "$target_path" > "$signature_report" 2>&1
    grep -Fq "Identifier=$expected_identifier" "$signature_report" || fail "wrong signing identifier for $target_path"
    grep -Fq "TeamIdentifier=$team_id" "$signature_report" || fail "wrong signing team for $target_path"
    grep -Fq "Authority=Developer ID Application:" "$signature_report" || fail "wrong signing identity for $target_path"
    grep -Fq "identifier \"$expected_identifier\"" "$signature_report" || fail "designated requirement omitted $expected_identifier"
    grep -Fq "certificate leaf[subject.OU] = $team_id" "$signature_report" || fail "designated requirement omitted team $team_id"
    grep -Fq "anchor apple generic" "$signature_report" || fail "designated requirement omitted Apple anchor"

    "$codesign_tool" --display --entitlements - "$target_path" > "$entitlements_report" 2>/dev/null || fail "could not read entitlements for $target_path"
    grep -Fq "[Dict]" "$entitlements_report" || fail "malformed entitlements for $target_path"
    if grep -Fq "com.apple.security.get-task-allow" "$entitlements_report"; then
        fail "release entitlement get-task-allow is forbidden for $target_path"
    fi
    if [[ "$expected_identifier" == "$helper_bundle_id" ]]; then
        grep -Fq "$team_id.$helper_bundle_id" "$entitlements_report" || fail "helper application identifier entitlement is wrong"
    fi
}

verify_signature "$app_path" "$app_bundle_id"
verify_signature "$helper_path" "$helper_bundle_id"

"$ditto_tool" -c -k --sequesterRsrc --keepParent "$app_path" "$submission_zip"
notarization_id="$(XCRUN_TOOL="$xcrun_tool" PLUTIL_TOOL="$plutil_tool" \
    NOTARY_KEY_ID="$notary_key_id" \
    NOTARY_ISSUER_ID="$notary_issuer_id" \
    NOTARY_KEY_PATH="$notary_key_path" \
    "$notarize_script" "$submission_zip")"
readonly notarization_id

"$xcrun_tool" stapler staple "$app_path" || fail "failed to staple notarization ticket"
"$xcrun_tool" stapler validate "$app_path" || fail "stapled notarization ticket validation failed"
verify_signature "$app_path" "$app_bundle_id"
verify_signature "$helper_path" "$helper_bundle_id"
"$spctl_tool" --assess --type execute --verbose=4 "$app_path" || fail "Gatekeeper assessment failed"

"$ditto_tool" -c -k --sequesterRsrc --keepParent "$app_path" "$release_zip"

readonly sign_update_tool="${SPARKLE_SIGN_UPDATE_PATH:-$derived_data/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update}"
require_tool "SPARKLE_SIGN_UPDATE_PATH" "$sign_update_tool"
if [[ -n "$sparkle_private_key_file" ]]; then
    sparkle_signature="$("$sign_update_tool" --ed-key-file "$sparkle_private_key_file" -p "$release_zip")"
else
    sparkle_signature="$("$sign_update_tool" --account "$sparkle_keychain_account" -p "$release_zip")"
fi
readonly sparkle_signature
[[ "$sparkle_signature" =~ ^[A-Za-z0-9+/]{86}==[[:space:]]*$ ]] || fail "Sparkle signer did not return an Ed25519 signature"
printf '%s\n' "$sparkle_signature" > "$staged_signature_file"

checksum="$("$shasum_tool" -a 256 "$release_zip" | awk '{ print $1 }')"
readonly checksum
[[ "$checksum" =~ ^[a-fA-F0-9]{64}$ ]] || fail "failed to calculate SHA-256 checksum"
printf '%s  %s\n' "$checksum" "Xcodes.zip" > "$staged_checksum_file"
cat > "$staged_manifest_file" <<EOF
tag=$release_tag
version=$release_version
build=$project_build
bundle_id=$app_bundle_id
helper_bundle_id=$helper_bundle_id
team_id=$team_id
notarization_id=$notarization_id
archive=Xcodes.zip
sha256=$checksum
sparkle_ed_signature=$sparkle_signature
EOF

/bin/cp "$release_zip" "$final_zip"
/bin/cp "$staged_signature_file" "$signature_file"
/bin/cp "$staged_checksum_file" "$checksum_file"
/bin/cp "$staged_manifest_file" "$manifest_file"

printf 'Created %s\n' "$final_zip"
printf 'Sparkle signature: %s\n' "$signature_file"
printf 'SHA-256: %s\n' "$checksum_file"
printf 'Manifest: %s\n' "$manifest_file"
