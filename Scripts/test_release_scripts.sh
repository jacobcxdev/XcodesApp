#!/bin/bash

set -euo pipefail

scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly scripts_dir
readonly package_script="$scripts_dir/package_release.sh"
readonly notarize_script="$scripts_dir/notarize.sh"
readonly export_options="$scripts_dir/export_options.plist"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/xcodes-release-tests.XXXXXX")"
readonly test_root

cleanup() {
    case "$test_root" in
        "${TMPDIR:-/tmp}"/xcodes-release-tests.*|/private"${TMPDIR:-/tmp}"/xcodes-release-tests.*)
            rm -rf -- "$test_root"
            ;;
        *)
            printf 'warning: refused unsafe test cleanup: %s\n' "$test_root" >&2
            ;;
    esac
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

require_literal() {
    local literal="$1"
    local file="$2"
    grep -Fq -- "$literal" "$file" || fail "Missing '$literal' in ${file##*/}"
}

expect_failure() {
    local expected="$1"
    shift
    local output_file="$test_root/failure.log"

    if "$@" > "$output_file" 2>&1; then
        fail "Command unexpectedly succeeded; expected '$expected'"
    fi
    grep -Fq -- "$expected" "$output_file" || {
        sed -n '1,80p' "$output_file" >&2
        fail "Failure did not contain '$expected'"
    }
}

for script in "$package_script" "$notarize_script"; do
    require_literal "set -euo pipefail" "$script"
    require_literal "mktemp -d" "$script"
    require_literal "trap cleanup EXIT" "$script"
done

for literal in \
    "release tag must match vX.Y.Z exactly" \
    "tracked working tree must be clean" \
    "restore_generated_source" \
    "K2648T24P4" \
    "dev.jacobcx.Xcodes" \
    "dev.jacobcx.Xcodes.Helper" \
    "Developer ID Application" \
    "stapler validate" \
    "codesign_tool\" --verify --deep --strict" \
    "codesign_tool\" --display --entitlements -" \
    "spctl_tool\" --assess --type execute --verbose=4" \
    "SPARKLE_SIGN_UPDATE_PATH" \
    "SPARKLE_PRIVATE_KEY_FILE" \
    "sparkle-signature.txt" \
    "release-manifest.txt"; do
    require_literal "$literal" "$package_script"
done

for literal in \
    "NOTARY_KEY_ID is required" \
    "NOTARY_ISSUER_ID is required" \
    "NOTARY_KEY_PATH" \
    "--output-format plist" \
    "Accepted"; do
    require_literal "$literal" "$notarize_script"
done

if grep -Eq 'rm[[:space:]]+-rf[[:space:]]+(--[[:space:]]+)?[^\"]*(Archive|Product)' "$package_script"; then
    fail "Broad workspace cleanup remains in package_release.sh"
fi
if grep -Eq "rm[[:space:]].*(archive_path|\\\$1)" "$notarize_script"; then
    fail "notarize.sh deletes caller artefacts"
fi

[[ "$(/usr/bin/plutil -extract method raw "$export_options")" == "developer-id" ]] || fail "Export method must be developer-id"
[[ "$(/usr/bin/plutil -extract teamID raw "$export_options")" == "K2648T24P4" ]] || fail "Export team must be K2648T24P4"
[[ "$(/usr/bin/plutil -extract signingStyle raw "$export_options")" == "manual" ]] || fail "Export signing must be manual"

readonly dispatcher="$test_root/tool-dispatcher"
cat > "$dispatcher" <<'DISPATCHER'
#!/bin/bash
set -euo pipefail

tool="$(basename "$0")"

argument_after() {
    local wanted="$1"
    shift
    while (($#)); do
        if [[ "$1" == "$wanted" ]]; then
            [[ $# -ge 2 ]] || exit 2
            printf '%s\n' "$2"
            return
        fi
        shift
    done
    exit 2
}

case "$tool" in
    git)
        case "${1:-}" in
            status)
                [[ "${FAKE_DIRTY:-0}" == "1" ]] && printf ' M tracked-file\n'
                ;;
            tag)
                printf '%s\n' "${FAKE_TAG:-v4.0.4}"
                ;;
            *) exit 2 ;;
        esac
        ;;
    security)
        if [[ "${FAKE_CERT_MISSING:-0}" != "1" ]]; then
            printf '  1) FAKE "Developer ID Application: Test (K2648T24P4)"\n'
        fi
        ;;
    xcodebuild)
        if [[ " $* " == *" -showBuildSettings "* ]]; then
            printf '    MARKETING_VERSION = %s\n' "${FAKE_VERSION:-4.0.4}"
            printf '    CURRENT_PROJECT_VERSION = %s\n' "${FAKE_BUILD:-39}"
        elif [[ "${1:-}" == "archive" ]]; then
            archive_path="$(argument_after -archivePath "$@")"
            app_path="$archive_path/Products/Applications/Xcodes.app"
            helper_path="$app_path/Contents/Library/LaunchServices/dev.jacobcx.Xcodes.Helper"
            mkdir -p "$(dirname "$helper_path")"
            printf '#!/bin/sh\nexit 0\n' > "$helper_path"
            chmod +x "$helper_path"
            cat > "$app_path/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>${FAKE_APP_BUNDLE_ID:-dev.jacobcx.Xcodes}</string>
<key>CFBundleShortVersionString</key><string>${FAKE_EXPORTED_VERSION:-${FAKE_VERSION:-4.0.4}}</string>
<key>CFBundleVersion</key><string>${FAKE_EXPORTED_BUILD:-${FAKE_BUILD:-39}}</string>
</dict></plist>
PLIST
            printf 'generated licence\n' > "$PWD/Xcodes/Resources/Licenses.rtf"
        elif [[ "${1:-}" == "-exportArchive" ]]; then
            archive_path="$(argument_after -archivePath "$@")"
            export_path="$(argument_after -exportPath "$@")"
            mkdir -p "$export_path"
            cp -R "$archive_path/Products/Applications/Xcodes.app" "$export_path/Xcodes.app"
        else
            exit 2
        fi
        ;;
    codesign)
        [[ "${FAKE_CODESIGN_VERIFY_FAIL:-0}" != "1" ]] || exit 1
        target="${!#}"
        if [[ "$target" == *.Helper ]]; then
            identifier="${FAKE_HELPER_IDENTIFIER:-dev.jacobcx.Xcodes.Helper}"
        else
            identifier="${FAKE_SIGN_IDENTIFIER:-dev.jacobcx.Xcodes}"
        fi
        team="${FAKE_SIGN_TEAM:-K2648T24P4}"
        authority="${FAKE_SIGN_AUTHORITY:-Developer ID Application: Test (K2648T24P4)}"
        if [[ " $* " == *" --entitlements - "* ]]; then
            printf '[Dict]\n'
            if [[ "$target" == *.Helper ]]; then
                printf '\t[Key] com.apple.application-identifier\n'
                printf '\t\t[String] %s.%s\n' "$team" "$identifier"
            fi
            [[ "${FAKE_DEBUG_ENTITLEMENT:-0}" != "1" ]] || printf '\t[Key] com.apple.security.get-task-allow\n'
        elif [[ " $* " == *" --display "* ]]; then
            printf 'Identifier=%s\n' "$identifier" >&2
            printf 'Authority=%s\n' "$authority" >&2
            printf 'TeamIdentifier=%s\n' "$team" >&2
            printf 'designated => identifier "%s" and anchor apple generic and certificate leaf[subject.OU] = %s\n' "$identifier" "$team" >&2
        fi
        ;;
    ditto)
        output="${!#}"
        mkdir -p "$(dirname "$output")"
        printf 'fake zip\n' > "$output"
        ;;
    xcrun)
        if [[ "${1:-}" == "notarytool" ]]; then
            cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>id</key><string>00000000-0000-0000-0000-000000000000</string>
<key>status</key><string>${FAKE_NOTARY_STATUS:-Accepted}</string>
</dict></plist>
PLIST
        elif [[ "${1:-}" == "stapler" && "${2:-}" == "staple" ]]; then
            [[ "${FAKE_STAPLE_MISSING:-0}" != "1" ]] || exit 1
            touch "$3/.fake-stapled"
        elif [[ "${1:-}" == "stapler" && "${2:-}" == "validate" ]]; then
            [[ -f "$3/.fake-stapled" ]] || exit 1
        else
            exit 2
        fi
        ;;
    spctl)
        [[ "${FAKE_SPCTL_FAIL:-0}" != "1" ]]
        ;;
    sign_update)
        [[ "${FAKE_SIGNATURE_MISSING:-0}" != "1" ]] || exit 0
        printf '%086d==\n' 0 | tr '0' 'A'
        ;;
    *) exit 2 ;;
esac
DISPATCHER
chmod +x "$dispatcher"

make_fixture() {
    local name="$1"
    local fixture="$test_root/$name"
    local tool

    mkdir -p "$fixture/Scripts" "$fixture/bin" "$fixture/Xcodes.xcodeproj" "$fixture/Xcodes/Resources"
    cp "$package_script" "$notarize_script" "$export_options" "$fixture/Scripts/"
    chmod +x "$fixture/Scripts/package_release.sh" "$fixture/Scripts/notarize.sh"
    for tool in git security xcodebuild codesign ditto xcrun spctl sign_update; do
        ln -s "$dispatcher" "$fixture/bin/$tool"
    done
    printf 'fake notary key\n' > "$fixture/notary-key.p8"
    printf 'fake sparkle key\n' > "$fixture/sparkle-key"
    printf 'committed licence\n' > "$fixture/Xcodes/Resources/Licenses.rtf"
    printf '%s\n' "$fixture"
}

run_package() {
    local fixture="$1"
    local tag="$2"
    shift 2

    env \
        GIT_TOOL="$fixture/bin/git" \
        XCODEBUILD_TOOL="$fixture/bin/xcodebuild" \
        SECURITY_TOOL="$fixture/bin/security" \
        CODESIGN_TOOL="$fixture/bin/codesign" \
        PLUTIL_TOOL=/usr/bin/plutil \
        DITTO_TOOL="$fixture/bin/ditto" \
        XCRUN_TOOL="$fixture/bin/xcrun" \
        SPCTL_TOOL="$fixture/bin/spctl" \
        SHASUM_TOOL=/usr/bin/shasum \
        SPARKLE_SIGN_UPDATE_PATH="$fixture/bin/sign_update" \
        SPARKLE_PRIVATE_KEY_FILE="$fixture/sparkle-key" \
        NOTARY_KEY_ID=TESTKEY123 \
        NOTARY_ISSUER_ID=00000000-0000-0000-0000-000000000000 \
        NOTARY_KEY_PATH="$fixture/notary-key.p8" \
        "$@" \
        bash "$fixture/Scripts/package_release.sh" "$tag"
}

fixture="$(make_fixture invalid-tag)"
expect_failure "release tag must match vX.Y.Z exactly" run_package "$fixture" "4.0.4"

fixture="$(make_fixture dirty)"
expect_failure "tracked working tree must be clean" run_package "$fixture" "v4.0.4" FAKE_DIRTY=1

fixture="$(make_fixture wrong-head-tag)"
expect_failure "must point at HEAD" run_package "$fixture" "v4.0.4" FAKE_TAG=v4.0.3

fixture="$(make_fixture version-mismatch)"
expect_failure "does not match MARKETING_VERSION" run_package "$fixture" "v4.0.4" FAKE_VERSION=4.0.3

fixture="$(make_fixture missing-credentials)"
expect_failure "NOTARY_KEY_ID is required" env \
    GIT_TOOL="$fixture/bin/git" \
    XCODEBUILD_TOOL="$fixture/bin/xcodebuild" \
    SECURITY_TOOL="$fixture/bin/security" \
    CODESIGN_TOOL="$fixture/bin/codesign" \
    PLUTIL_TOOL=/usr/bin/plutil \
    DITTO_TOOL="$fixture/bin/ditto" \
    XCRUN_TOOL="$fixture/bin/xcrun" \
    SPCTL_TOOL="$fixture/bin/spctl" \
    SHASUM_TOOL=/usr/bin/shasum \
    bash "$fixture/Scripts/package_release.sh" v4.0.4

fixture="$(make_fixture relative-key-path)"
expect_failure "NOTARY_KEY_PATH must be an absolute path" run_package "$fixture" "v4.0.4" NOTARY_KEY_PATH=relative-key.p8

fixture="$(make_fixture missing-certificate)"
expect_failure "Developer ID Application certificate for team K2648T24P4 is missing" run_package "$fixture" "v4.0.4" FAKE_CERT_MISSING=1

fixture="$(make_fixture relative-sparkle-key-path)"
expect_failure "SPARKLE_PRIVATE_KEY_FILE must be an absolute path" run_package "$fixture" "v4.0.4" SPARKLE_PRIVATE_KEY_FILE=relative-sparkle-key

fixture="$(make_fixture wrong-app-bundle)"
expect_failure "exported app identifier" run_package "$fixture" "v4.0.4" FAKE_APP_BUNDLE_ID=example.wrong

fixture="$(make_fixture wrong-helper-signature)"
expect_failure "wrong signing identifier" run_package "$fixture" "v4.0.4" FAKE_HELPER_IDENTIFIER=example.wrong.Helper

fixture="$(make_fixture wrong-team)"
expect_failure "wrong signing team" run_package "$fixture" "v4.0.4" FAKE_SIGN_TEAM=WRONGTEAM

fixture="$(make_fixture wrong-identity)"
expect_failure "wrong signing identity" run_package "$fixture" "v4.0.4" FAKE_SIGN_AUTHORITY='Apple Development: Test'

fixture="$(make_fixture debug-entitlement)"
expect_failure "release entitlement get-task-allow is forbidden" run_package "$fixture" "v4.0.4" FAKE_DEBUG_ENTITLEMENT=1

fixture="$(make_fixture failed-notary)"
expect_failure "notarization status was 'Invalid'" run_package "$fixture" "v4.0.4" FAKE_NOTARY_STATUS=Invalid

fixture="$(make_fixture missing-staple)"
expect_failure "failed to staple notarization ticket" run_package "$fixture" "v4.0.4" FAKE_STAPLE_MISSING=1

fixture="$(make_fixture failed-gatekeeper)"
expect_failure "Gatekeeper assessment failed" run_package "$fixture" "v4.0.4" FAKE_SPCTL_FAIL=1

fixture="$(make_fixture missing-signature)"
expect_failure "Sparkle signer did not return an Ed25519 signature" run_package "$fixture" "v4.0.4" FAKE_SIGNATURE_MISSING=1
[[ ! -e "$fixture/Product/Xcodes.zip" ]] || fail "Failed flow published a partial Product/Xcodes.zip"
[[ "$(<"$fixture/Xcodes/Resources/Licenses.rtf")" == "committed licence" ]] || fail "Failed release did not restore generated licences"

fixture="$(make_fixture failed-notary-preserves-archive)"
printf 'caller archive\n' > "$fixture/caller.zip"
expect_failure "notarization status was 'Invalid'" env \
    XCRUN_TOOL="$fixture/bin/xcrun" \
    PLUTIL_TOOL=/usr/bin/plutil \
    NOTARY_KEY_ID=TESTKEY123 \
    NOTARY_ISSUER_ID=00000000-0000-0000-0000-000000000000 \
    NOTARY_KEY_PATH="$fixture/notary-key.p8" \
    FAKE_NOTARY_STATUS=Invalid \
    bash "$fixture/Scripts/notarize.sh" "$fixture/caller.zip"
[[ -f "$fixture/caller.zip" ]] || fail "notarize.sh deleted caller archive"

fixture="$(make_fixture successful-flow)"
run_package "$fixture" "v4.0.4" > "$test_root/success.log"
for output in Xcodes.zip Xcodes.zip.sha256 sparkle-signature.txt release-manifest.txt; do
    [[ -s "$fixture/Product/$output" ]] || fail "Successful flow omitted Product/$output"
done
grep -Fq 'tag=v4.0.4' "$fixture/Product/release-manifest.txt" || fail "Manifest omitted release tag"
grep -Fq 'team_id=K2648T24P4' "$fixture/Product/release-manifest.txt" || fail "Manifest omitted release team"
[[ "$(<"$fixture/Xcodes/Resources/Licenses.rtf")" == "committed licence" ]] || fail "Release build left generated licences in tracked source"
expect_failure "refusing to overwrite existing release output" run_package "$fixture" "v4.0.4"

printf 'Release script contracts passed.\n'
