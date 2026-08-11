#!/bin/bash

set -euo pipefail

# Usage: package_release.sh vX.Y.ZbN
# Required environment: NOTARY_KEY_ID, NOTARY_ISSUER_ID, NOTARY_KEY_PATH.
# Optional Sparkle input: SPARKLE_PRIVATE_KEY_FILE; otherwise dedicated Keychain account is used.
# Outputs: Product/<tag>/Xcodes.zip, Product/<tag>/Xcodes.zip.sha256,
#          Product/<tag>/sparkle-signature.txt, and Product/<tag>/release-manifest.txt.

readonly team_id="K2648T24P4"
readonly app_bundle_id="dev.jacobcx.Xcodes"
readonly helper_bundle_id="dev.jacobcx.Xcodes.Helper"
readonly signing_identity="Developer ID Application"
readonly sparkle_keychain_account="${SPARKLE_KEYCHAIN_ACCOUNT:-dev.jacobcx.Xcodes}"

scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly scripts_dir
repository_root="$(cd "$scripts_dir/.." && pwd -P)"
readonly repository_root
readonly project_path="$repository_root/Xcodes.xcodeproj"
readonly export_options_path="$scripts_dir/export_options.plist"
readonly notarize_script="$scripts_dir/notarize.sh"
readonly generated_licences_path="$repository_root/Xcodes/Resources/Licenses.rtf"
readonly product_dir="$repository_root/Product"

readonly git_tool="${GIT_TOOL:-/usr/bin/git}"
readonly xcodebuild_tool="${XCODEBUILD_TOOL:-/usr/bin/xcodebuild}"
readonly security_tool="${SECURITY_TOOL:-/usr/bin/security}"
readonly codesign_tool="${CODESIGN_TOOL:-/usr/bin/codesign}"
readonly plutil_tool="${PLUTIL_TOOL:-/usr/bin/plutil}"
readonly ditto_tool="${DITTO_TOOL:-/usr/bin/ditto}"
readonly xcrun_tool="${XCRUN_TOOL:-/usr/bin/xcrun}"
readonly spctl_tool="${SPCTL_TOOL:-/usr/sbin/spctl}"
readonly shasum_tool="${SHASUM_TOOL:-/usr/bin/shasum}"
readonly mv_tool="${MV_TOOL:-/bin/mv}"

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
    "SHASUM_TOOL:$shasum_tool" \
    "MV_TOOL:$mv_tool"; do
    require_tool "${tool_spec%%:*}" "${tool_spec#*:}"
done

readonly release_tag="${1:-${RELEASE_TAG:-${GITHUB_REF_NAME:-}}}"
if [[ ! "$release_tag" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)b(0|[1-9][0-9]*)$ ]]; then
    fail "release tag must match vX.Y.ZbN exactly"
fi
readonly release_version="${BASH_REMATCH[1]}"
readonly release_build="${BASH_REMATCH[2]}"
readonly release_dir="$product_dir/$release_tag"
readonly release_locks_dir="$product_dir/.release-locks"
readonly release_lock_dir="$release_locks_dir/$release_tag"
readonly final_zip="$release_dir/Xcodes.zip"
readonly signature_file="$release_dir/sparkle-signature.txt"
readonly checksum_file="$release_dir/Xcodes.zip.sha256"
readonly manifest_file="$release_dir/release-manifest.txt"

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
[[ "$release_build" == "$project_build" ]] || fail "tag build '$release_build' does not match CURRENT_PROJECT_VERSION '$project_build'"

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

[[ ! -L "$product_dir" ]] || fail "Product output directory must not be a symbolic link"
if [[ -e "$product_dir" ]]; then
    [[ -d "$product_dir" ]] || fail "Product output path must be a directory"
else
    /bin/mkdir "$product_dir"
fi
product_canonical="$(cd "$product_dir" && pwd -P)"
readonly product_canonical
[[ "$product_canonical" == "$product_dir" ]] || fail "Product output directory escaped the repository"
[[ ! -e "$release_dir" && ! -L "$release_dir" ]] || fail "release destination already exists or is a symbolic link: $release_dir"
[[ -f "$generated_licences_path" ]] || fail "tracked licences file is missing: $generated_licences_path"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/xcodes-release.XXXXXX")"
readonly work_dir
readonly licences_backup="$work_dir/Licenses.rtf"
publication_staging_dir=""
publication_staging_identity=""
published_release_dir=""
published_release_identity=""
release_lock_identity=""

path_identity() {
    local path="$1"

    [[ -d "$path" && ! -L "$path" ]] || return 1
    /usr/bin/stat -f '%d:%i' "$path"
}

remove_owned_directory() {
    local path="$1"
    local expected_identity="$2"
    local description="$3"
    local current_identity

    current_identity="$(path_identity "$path" 2>/dev/null || true)"
    if [[ -n "$expected_identity" && "$current_identity" == "$expected_identity" ]]; then
        rm -rf -- "$path"
    elif [[ -e "$path" || -L "$path" ]]; then
        printf 'warning: refused to remove unowned %s: %s\n' "$description" "$path" >&2
    fi
}

remove_owned_nested_staging() {
    local owned_staging_basename="$1"
    local nested_staging="$release_dir/$owned_staging_basename"
    local nested_identity

    nested_identity="$(path_identity "$nested_staging" 2>/dev/null || true)"
    if [[ -n "$publication_staging_identity" && "$nested_identity" == "$publication_staging_identity" ]]; then
        remove_owned_directory \
            "$nested_staging" \
            "$publication_staging_identity" \
            "nested publication staging directory"
    fi
}

restore_generated_source() {
    if [[ -f "$licences_backup" ]] && ! /usr/bin/cmp -s "$licences_backup" "$generated_licences_path"; then
        /bin/cp "$licences_backup" "$generated_licences_path"
    fi
}

cleanup() {
    local current_lock_identity

    restore_generated_source
    if [[ -n "$publication_staging_dir" ]]; then
        case "$publication_staging_dir" in
            "$product_dir"/."$release_tag".staging.*)
                remove_owned_directory \
                    "$publication_staging_dir" \
                    "$publication_staging_identity" \
                    "publication staging directory"
                ;;
            *)
                printf 'warning: refused unsafe publication staging cleanup: %s\n' "$publication_staging_dir" >&2
                ;;
        esac
    fi
    if [[ -n "$published_release_dir" ]]; then
        case "$published_release_dir" in
            "$release_dir")
                remove_owned_directory \
                    "$published_release_dir" \
                    "$published_release_identity" \
                    "published release rollback"
                ;;
            *)
                printf 'warning: refused unsafe published release rollback: %s\n' "$published_release_dir" >&2
                ;;
        esac
    fi
    if [[ -n "$release_lock_identity" ]]; then
        current_lock_identity="$(path_identity "$release_lock_dir" 2>/dev/null || true)"
        if [[ "$current_lock_identity" == "$release_lock_identity" ]]; then
            /bin/rmdir "$release_lock_dir" 2>/dev/null || \
                printf 'warning: owned release lock was not empty: %s\n' "$release_lock_dir" >&2
        elif [[ -e "$release_lock_dir" || -L "$release_lock_dir" ]]; then
            printf 'warning: refused to remove unowned release lock: %s\n' "$release_lock_dir" >&2
        fi
    fi
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

[[ ! -L "$release_locks_dir" ]] || fail "release lock directory must not be a symbolic link"
if [[ ! -e "$release_locks_dir" ]]; then
    /bin/mkdir "$release_locks_dir" 2>/dev/null || true
fi
[[ -d "$release_locks_dir" && ! -L "$release_locks_dir" ]] || fail "release lock path must be a directory"
release_locks_canonical="$(cd "$release_locks_dir" && pwd -P)"
readonly release_locks_canonical
[[ "$release_locks_canonical" == "$product_canonical/.release-locks" ]] || fail "release lock directory escaped Product"
if ! /bin/mkdir "$release_lock_dir" 2>/dev/null; then
    fail "release lock is already held for $release_tag; inspect and remove a stale lock manually"
fi
release_lock_identity="$(path_identity "$release_lock_dir")" || fail "could not record owned release lock identity"

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
readonly zip_validation_dir="$work_dir/ZipValidation"
readonly sparkle_validation_dir="$work_dir/SparkleValidation"
readonly sparkle_appcast="$sparkle_validation_dir/appcast.xml"
readonly sparkle_report="$work_dir/generate-appcast.log"
readonly signature_bytes="$work_dir/sparkle-signature.bin"

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
[[ "$app_build" == "$release_build" ]] || fail "exported app build '$app_build' does not match tag build '$release_build'"
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

verify_app_identity() {
    local target_app="$1"
    local target_helper="$target_app/Contents/Library/LaunchServices/$helper_bundle_id"
    local target_version
    local target_build
    local target_identifier

    [[ -d "$target_app" && ! -L "$target_app" ]] || fail "validated ZIP did not contain a regular Xcodes.app directory"
    [[ -f "$target_helper" ]] || fail "validated ZIP omitted $helper_bundle_id"
    target_version="$("$plutil_tool" -extract CFBundleShortVersionString raw "$target_app/Contents/Info.plist")"
    target_build="$("$plutil_tool" -extract CFBundleVersion raw "$target_app/Contents/Info.plist")"
    target_identifier="$("$plutil_tool" -extract CFBundleIdentifier raw "$target_app/Contents/Info.plist")"
    [[ "$target_version" == "$release_version" ]] || fail "validated ZIP app version '$target_version' does not match tag '$release_version'"
    [[ "$target_build" == "$release_build" ]] || fail "validated ZIP app build '$target_build' does not match tag build '$release_build'"
    [[ "$target_identifier" == "$app_bundle_id" ]] || fail "validated ZIP app identifier '$target_identifier' is not '$app_bundle_id'"
    verify_signature "$target_app" "$app_bundle_id"
    verify_signature "$target_helper" "$helper_bundle_id"
}

validate_release_zip() {
    local archive="$1"
    local entry
    local link_path
    local link_target
    local link_target_parent
    local link_target_name
    local canonical_target_parent
    local extracted_app="$zip_validation_dir/Xcodes.app"

    /usr/bin/unzip -tq "$archive" >/dev/null || fail "release ZIP integrity check failed"
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        case "$entry" in
            Xcodes.app|Xcodes.app/*) ;;
            *) fail "release ZIP contains an unexpected entry: $entry" ;;
        esac
        case "/$entry/" in
            *"/../"*|*"/./"*) fail "release ZIP contains an unsafe path: $entry" ;;
        esac
        case "$entry" in
            *\\*) fail "release ZIP contains an unsafe path: $entry" ;;
        esac
    done < <(/usr/bin/unzip -Z1 "$archive")

    /bin/mkdir "$zip_validation_dir"
    /usr/bin/unzip -q "$archive" -d "$zip_validation_dir" || fail "release ZIP extraction failed"
    [[ -d "$extracted_app" && ! -L "$extracted_app" ]] || fail "validated ZIP did not contain a regular Xcodes.app directory"
    extracted_app="$(cd "$extracted_app" && pwd -P)"
    while IFS= read -r -d '' link_path; do
        link_target="$(/usr/bin/readlink "$link_path")"
        [[ -n "$link_target" && "$link_target" != /* ]] || fail "release ZIP contains an unsafe symbolic link: $link_path"
        link_target_parent="$(dirname "$link_path")/$(dirname "$link_target")"
        link_target_name="$(basename "$link_target")"
        [[ "$link_target_name" != "." && "$link_target_name" != ".." ]] || fail "release ZIP contains an unsafe symbolic link: $link_path"
        canonical_target_parent="$(cd "$link_target_parent" 2>/dev/null && pwd -P)" || fail "release ZIP contains a dangling symbolic link: $link_path"
        case "$canonical_target_parent/$link_target_name" in
            "$extracted_app"/*) ;;
            *) fail "release ZIP symbolic link escapes Xcodes.app: $link_path" ;;
        esac
    done < <(/usr/bin/find "$extracted_app" -type l -print0)
    verify_app_identity "$extracted_app"
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

"$ditto_tool" -c -k --norsrc --keepParent "$app_path" "$release_zip"
validate_release_zip "$release_zip"

readonly sign_update_tool="${SPARKLE_SIGN_UPDATE_PATH:-$derived_data/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update}"
readonly generate_appcast_tool="${SPARKLE_GENERATE_APPCAST_PATH:-$derived_data/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast}"
require_tool "SPARKLE_SIGN_UPDATE_PATH" "$sign_update_tool"
require_tool "SPARKLE_GENERATE_APPCAST_PATH" "$generate_appcast_tool"
if [[ -n "$sparkle_private_key_file" ]]; then
    sparkle_signature="$("$sign_update_tool" --ed-key-file "$sparkle_private_key_file" -p "$release_zip")"
else
    sparkle_signature="$("$sign_update_tool" --account "$sparkle_keychain_account" -p "$release_zip")"
fi
readonly sparkle_signature
[[ "$sparkle_signature" =~ ^[A-Za-z0-9+/]{86}==$ ]] || fail "Sparkle signer did not return a canonical Ed25519 signature"
printf '%s' "$sparkle_signature" | /usr/bin/base64 -D > "$signature_bytes" 2>/dev/null || fail "Sparkle signature was not valid Base64"
signature_byte_count="$(/usr/bin/wc -c < "$signature_bytes" | tr -d '[:space:]')"
readonly signature_byte_count
[[ "$signature_byte_count" == "64" ]] || fail "Sparkle signature did not decode to 64 bytes"
canonical_signature="$(/usr/bin/base64 < "$signature_bytes" | tr -d '\n')"
readonly canonical_signature
[[ "$canonical_signature" == "$sparkle_signature" ]] || fail "Sparkle signer did not return canonical Base64"
printf '%s\n' "$sparkle_signature" > "$staged_signature_file"

/bin/mkdir "$sparkle_validation_dir"
/bin/cp "$release_zip" "$sparkle_validation_dir/Xcodes.zip"
if [[ -n "$sparkle_private_key_file" ]]; then
    "$generate_appcast_tool" \
        --ed-key-file "$sparkle_private_key_file" \
        --versions "$release_build" \
        --maximum-versions 1 \
        --maximum-deltas 0 \
        -o "$sparkle_appcast" \
        "$sparkle_validation_dir" > "$sparkle_report" 2>&1 || fail "Sparkle key correspondence validation failed"
else
    "$generate_appcast_tool" \
        --account "$sparkle_keychain_account" \
        --versions "$release_build" \
        --maximum-versions 1 \
        --maximum-deltas 0 \
        -o "$sparkle_appcast" \
        "$sparkle_validation_dir" > "$sparkle_report" 2>&1 || fail "Sparkle key correspondence validation failed"
fi
if grep -Fq "Warning: SUPublicEDKey in the app " "$sparkle_report" && \
    grep -Fq "does not match key EdDSA in the Keychain. Run generate_keys and update Info.plist to match" "$sparkle_report"; then
    fail "Sparkle signing key does not match exported SUPublicEDKey"
fi
[[ -s "$sparkle_appcast" ]] || fail "Sparkle key correspondence validation did not create an appcast"
/usr/bin/xmllint --noout "$sparkle_appcast" 2>/dev/null || fail "Sparkle key correspondence validation created an invalid appcast"
appcast_signature="$(/usr/bin/xmllint --xpath 'string(//*[local-name()="enclosure"]/@*[local-name()="edSignature"])' "$sparkle_appcast")"
readonly appcast_signature
[[ "$appcast_signature" == "$sparkle_signature" ]] || fail "Sparkle signing key does not match exported SUPublicEDKey"

checksum="$("$shasum_tool" -a 256 "$release_zip" | awk '{ print $1 }')"
readonly checksum
[[ "$checksum" =~ ^[a-fA-F0-9]{64}$ ]] || fail "failed to calculate SHA-256 checksum"
printf '%s  %s\n' "$checksum" "Xcodes.zip" > "$staged_checksum_file"
printf 'tag=%s\nversion=%s\nbuild=%s\nbundle_id=%s\nhelper_bundle_id=%s\nteam_id=%s\nnotarization_id=%s\narchive=%s\nsha256=%s\nsparkle_ed_signature=%s\n' \
    "$release_tag" \
    "$release_version" \
    "$release_build" \
    "$app_bundle_id" \
    "$helper_bundle_id" \
    "$team_id" \
    "$notarization_id" \
    "Xcodes.zip" \
    "$checksum" \
    "$sparkle_signature" > "$staged_manifest_file"

publication_staging_dir="$(mktemp -d "$product_dir/.${release_tag}.staging.XXXXXX")"
publication_staging_identity="$(path_identity "$publication_staging_dir")" || fail "could not record publication staging identity"
/bin/cp "$release_zip" "$publication_staging_dir/Xcodes.zip"
/bin/cp "$staged_signature_file" "$publication_staging_dir/sparkle-signature.txt"
/bin/cp "$staged_checksum_file" "$publication_staging_dir/Xcodes.zip.sha256"
/bin/cp "$staged_manifest_file" "$publication_staging_dir/release-manifest.txt"
for staged_output in Xcodes.zip sparkle-signature.txt Xcodes.zip.sha256 release-manifest.txt; do
    [[ -f "$publication_staging_dir/$staged_output" && ! -L "$publication_staging_dir/$staged_output" ]] || \
        fail "publication staging output is not a regular file: $staged_output"
done
staged_checksum="$("$shasum_tool" -a 256 "$publication_staging_dir/Xcodes.zip" | awk '{ print $1 }')"
readonly staged_checksum
[[ "$staged_checksum" == "$checksum" ]] || fail "publication staging ZIP checksum changed"

[[ ! -L "$product_dir" ]] || fail "Product output directory must not be a symbolic link"
[[ "$(cd "$product_dir" && pwd -P)" == "$product_canonical" ]] || fail "Product output directory escaped the repository"
[[ ! -L "$release_locks_dir" && "$(cd "$release_locks_dir" && pwd -P)" == "$release_locks_canonical" ]] || fail "release lock directory changed before publication"
[[ "$(path_identity "$release_lock_dir" 2>/dev/null || true)" == "$release_lock_identity" ]] || fail "owned release lock changed before publication"
[[ "$(path_identity "$publication_staging_dir" 2>/dev/null || true)" == "$publication_staging_identity" ]] || fail "publication staging identity changed before publication"
[[ ! -e "$release_dir" && ! -L "$release_dir" ]] || fail "release destination already exists or is a symbolic link: $release_dir"
staging_basename="${publication_staging_dir##*/}"
readonly staging_basename
if ! "$mv_tool" "$publication_staging_dir" "$release_dir"; then
    remove_owned_nested_staging "$staging_basename"
    fail "failed to publish complete release directory"
fi
destination_identity="$(path_identity "$release_dir" 2>/dev/null || true)"
readonly destination_identity
if [[ "$destination_identity" != "$publication_staging_identity" ]]; then
    remove_owned_nested_staging "$staging_basename"
    fail "release destination changed during atomic publication"
fi
published_release_dir="$release_dir"
published_release_identity="$destination_identity"
[[ ! -e "$publication_staging_dir" && ! -L "$publication_staging_dir" ]] || fail "atomic release directory publication did not complete"
publication_staging_dir=""
publication_staging_identity=""

published_checksum="$("$shasum_tool" -a 256 "$final_zip" | awk '{ print $1 }')"
readonly published_checksum
[[ "$published_checksum" == "$checksum" ]] || fail "published ZIP checksum changed"
published_release_dir=""
published_release_identity=""

printf 'Created %s\n' "$final_zip"
printf 'Sparkle signature: %s\n' "$signature_file"
printf 'SHA-256: %s\n' "$checksum_file"
printf 'Manifest: %s\n' "$manifest_file"
