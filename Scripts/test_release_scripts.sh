#!/bin/bash
# shellcheck disable=SC2016 # Mutation expressions intentionally match literal shell variables.

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
    "release tag must match vX.Y.ZbN exactly" \
    "tracked working tree must be clean" \
    "release lock is already held" \
    "/usr/bin/stat -f" \
    "restore_generated_source" \
    "K2648T24P4" \
    "dev.jacobcx.Xcodes" \
    "dev.jacobcx.Xcodes.Helper" \
    "Developer ID Application" \
    "stapler validate" \
    "codesign_tool\" --verify --deep --strict" \
    "codesign_tool\" --display --entitlements -" \
    "spctl_tool\" --assess --type execute --verbose=4" \
    "--norsrc --keepParent" \
    "/usr/bin/unzip -tq" \
    "/usr/bin/xmllint --noout" \
    "SPARKLE_SIGN_UPDATE_PATH" \
    "SPARKLE_GENERATE_APPCAST_PATH" \
    "SPARKLE_PRIVATE_KEY_FILE" \
    "sparkle-signature.txt" \
    "release-manifest.txt"; do
    require_literal "$literal" "$package_script"
done

for literal in \
    "NOTARY_KEY_ID is required" \
    "NOTARY_ISSUER_ID is required" \
    "NOTARY_KEY_PATH" \
    "--output-format json" \
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

record_call() {
    [[ -z "${FAKE_TOOL_LOG:-}" ]] || printf '%s %s\n' "$tool" "$*" >> "$FAKE_TOOL_LOG"
}

case "$tool" in
    git)
        case "${1:-}" in
            status)
                [[ "${FAKE_DIRTY:-0}" == "1" ]] && printf ' M tracked-file\n'
                ;;
            tag)
                printf '%s\n' "${FAKE_TAG:-v4.0.4b39}"
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
<key>SUPublicEDKey</key><string>AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=</string>
</dict></plist>
PLIST
            if [[ "${FAKE_UNSAFE_APP_SYMLINK:-0}" == "1" ]]; then
                ln -s /tmp "$app_path/Contents/UnsafeOutsideLink"
            fi
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
        record_call "$@"
        output="${!#}"
        if [[ "${FAKE_ZIP_MODE:-valid}" == "corrupt" ]]; then
            printf 'not a zip\n' > "$output"
        else
            /usr/bin/ditto "$@"
            if [[ "${FAKE_ZIP_MODE:-valid}" == "truncated" ]]; then
                /usr/bin/head -c 10 "$output" > "$output.truncated"
                /bin/mv "$output.truncated" "$output"
            elif [[ "${FAKE_ZIP_MODE:-valid}" == "extra" ]]; then
                extra_dir="$(mktemp -d "${TMPDIR:-/tmp}/xcodes-extra-payload.XXXXXX")"
                printf 'unexpected\n' > "$extra_dir/unexpected.txt"
                (cd "$extra_dir" && /usr/bin/zip -q "$output" unexpected.txt)
                rm -rf -- "$extra_dir"
            fi
        fi
        ;;
    xcrun)
        record_call "$@"
        if [[ "${1:-}" == "notarytool" ]]; then
            [[ "${2:-}" == "submit" && -f "${3:-}" ]] || exit 2
            [[ " $* " == *" --key ${NOTARY_KEY_PATH:-missing} "* ]] || exit 2
            [[ " $* " == *" --key-id ${NOTARY_KEY_ID:-missing} "* ]] || exit 2
            [[ " $* " == *" --issuer ${NOTARY_ISSUER_ID:-missing} "* ]] || exit 2
            [[ " $* " == *" --wait "* ]] || exit 2
            [[ " $* " == *" --output-format json "* ]] || exit 2
            printf '{"id":"%s","status":"%s"}\n' \
                "${FAKE_NOTARY_ID:-00000000-0000-0000-0000-000000000000}" \
                "${FAKE_NOTARY_STATUS:-Accepted}"
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
        record_call "$@"
        [[ "${FAKE_SIGNATURE_MISSING:-0}" != "1" ]] || exit 0
        if [[ "${FAKE_SIGNATURE_WHITESPACE:-0}" == "1" ]]; then
            printf ' %086d==\n' 0 | tr '0' 'A'
            exit 0
        fi
        printf '%086d==\n' 0 | tr '0' 'A'
        ;;
    generate_appcast)
        record_call "$@"
        output="$(argument_after -o "$@")"
        mkdir -p "$(dirname "$output")"
        if [[ "${FAKE_SPARKLE_KEY_MISMATCH:-0}" == "1" ]]; then
            printf '<rss xmlns:sparkle="https://sparkle-project.org"><enclosure /></rss>\n' > "$output"
            printf 'Warning: SUPublicEDKey in the app fake does not match key EdDSA in the Keychain. Run generate_keys and update Info.plist to match\n'
        else
            signature="$(printf '%086d==' 0 | tr '0' 'A')"
            printf '<rss xmlns:sparkle="https://sparkle-project.org"><enclosure sparkle:edSignature="%s" /></rss>\n' "$signature" > "$output"
        fi
        ;;
    mv)
        record_call "$@"
        [[ "${FAKE_PUBLISH_FAIL:-0}" != "1" ]] || exit 1
        if [[ "${FAKE_PUBLISH_RACE:-0}" == "1" ]]; then
            destination="${!#}"
            mkdir "$destination"
            printf 'caller sentinel\n' > "$destination/sentinel"
        fi
        /bin/mv "$@"
        [[ "${FAKE_PUBLISHED_CORRUPT:-0}" != "1" ]] || printf 'changed after publication\n' >> "${!#}/Xcodes.zip"
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
    for tool in git security xcodebuild codesign ditto xcrun spctl sign_update generate_appcast mv; do
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
        MV_TOOL="$fixture/bin/mv" \
        SPARKLE_SIGN_UPDATE_PATH="$fixture/bin/sign_update" \
        SPARKLE_GENERATE_APPCAST_PATH="$fixture/bin/generate_appcast" \
        SPARKLE_PRIVATE_KEY_FILE="$fixture/sparkle-key" \
        NOTARY_KEY_ID=TESTKEY123 \
        NOTARY_ISSUER_ID=00000000-0000-0000-0000-000000000000 \
        NOTARY_KEY_PATH="$fixture/notary-key.p8" \
        FAKE_TOOL_LOG="$fixture/tool.log" \
        "$@" \
        bash "$fixture/Scripts/package_release.sh" "$tag"
}

assert_no_release() {
    local fixture="$1"
    local release_path="$fixture/Product/v4.0.4b39"

    [[ ! -e "$release_path" && ! -L "$release_path" ]] || fail "Failed flow published a release directory"
    if [[ -d "$fixture/Product" && ! -L "$fixture/Product" ]]; then
        [[ -z "$(find "$fixture/Product" -maxdepth 1 -name '.v4.0.4b39.staging.*' -print -quit)" ]] || \
            fail "Failed flow left a publication staging directory"
    fi
}

fixture="$(make_fixture invalid-tag)"
expect_failure "release tag must match vX.Y.ZbN exactly" run_package "$fixture" "4.0.4b39"

fixture="$(make_fixture missing-build-tag)"
expect_failure "release tag must match vX.Y.ZbN exactly" run_package "$fixture" "v4.0.4"

fixture="$(make_fixture empty-build-tag)"
expect_failure "release tag must match vX.Y.ZbN exactly" run_package "$fixture" "v4.0.4b"

fixture="$(make_fixture dirty)"
expect_failure "tracked working tree must be clean" run_package "$fixture" "v4.0.4b39" FAKE_DIRTY=1

fixture="$(make_fixture wrong-head-tag)"
expect_failure "must point at HEAD" run_package "$fixture" "v4.0.4b39" FAKE_TAG=v4.0.4b38

fixture="$(make_fixture marketing-version-mismatch)"
expect_failure "does not match MARKETING_VERSION" run_package "$fixture" "v4.0.4b39" FAKE_VERSION=4.0.3

fixture="$(make_fixture project-build-mismatch)"
expect_failure "does not match CURRENT_PROJECT_VERSION" run_package "$fixture" "v4.0.4b39" FAKE_BUILD=38

fixture="$(make_fixture exported-version-mismatch)"
expect_failure "exported app version" run_package "$fixture" "v4.0.4b39" FAKE_EXPORTED_VERSION=4.0.3

fixture="$(make_fixture exported-build-mismatch)"
expect_failure "exported app build" run_package "$fixture" "v4.0.4b39" FAKE_EXPORTED_BUILD=38

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
    bash "$fixture/Scripts/package_release.sh" v4.0.4b39

fixture="$(make_fixture relative-key-path)"
expect_failure "NOTARY_KEY_PATH must be an absolute path" run_package "$fixture" "v4.0.4b39" NOTARY_KEY_PATH=relative-key.p8

fixture="$(make_fixture missing-certificate)"
expect_failure "Developer ID Application certificate for team K2648T24P4 is missing" run_package "$fixture" "v4.0.4b39" FAKE_CERT_MISSING=1

fixture="$(make_fixture relative-sparkle-key-path)"
expect_failure "SPARKLE_PRIVATE_KEY_FILE must be an absolute path" run_package "$fixture" "v4.0.4b39" SPARKLE_PRIVATE_KEY_FILE=relative-sparkle-key

fixture="$(make_fixture wrong-app-bundle)"
expect_failure "exported app identifier" run_package "$fixture" "v4.0.4b39" FAKE_APP_BUNDLE_ID=example.wrong

fixture="$(make_fixture wrong-helper-signature)"
expect_failure "wrong signing identifier" run_package "$fixture" "v4.0.4b39" FAKE_HELPER_IDENTIFIER=example.wrong.Helper

fixture="$(make_fixture wrong-team)"
expect_failure "wrong signing team" run_package "$fixture" "v4.0.4b39" FAKE_SIGN_TEAM=WRONGTEAM

fixture="$(make_fixture wrong-identity)"
expect_failure "wrong signing identity" run_package "$fixture" "v4.0.4b39" FAKE_SIGN_AUTHORITY='Apple Development: Test'

fixture="$(make_fixture debug-entitlement)"
expect_failure "release entitlement get-task-allow is forbidden" run_package "$fixture" "v4.0.4b39" FAKE_DEBUG_ENTITLEMENT=1

fixture="$(make_fixture failed-notary)"
expect_failure "notarization status was 'Invalid'" run_package "$fixture" "v4.0.4b39" FAKE_NOTARY_STATUS=Invalid

fixture="$(make_fixture invalid-notary-id)"
expect_failure "notarization response id must be a UUID" run_package "$fixture" "v4.0.4b39" FAKE_NOTARY_ID=not-a-uuid

fixture="$(make_fixture missing-staple)"
expect_failure "failed to staple notarization ticket" run_package "$fixture" "v4.0.4b39" FAKE_STAPLE_MISSING=1

fixture="$(make_fixture failed-gatekeeper)"
expect_failure "Gatekeeper assessment failed" run_package "$fixture" "v4.0.4b39" FAKE_SPCTL_FAIL=1

fixture="$(make_fixture missing-signature)"
expect_failure "Sparkle signer did not return a canonical Ed25519 signature" run_package "$fixture" "v4.0.4b39" FAKE_SIGNATURE_MISSING=1
assert_no_release "$fixture"
[[ "$(<"$fixture/Xcodes/Resources/Licenses.rtf")" == "committed licence" ]] || fail "Failed release did not restore generated licences"

fixture="$(make_fixture whitespace-signature)"
expect_failure "Sparkle signer did not return a canonical Ed25519 signature" run_package "$fixture" "v4.0.4b39" FAKE_SIGNATURE_WHITESPACE=1
assert_no_release "$fixture"

fixture="$(make_fixture sparkle-key-mismatch)"
expect_failure "Sparkle signing key does not match exported SUPublicEDKey" run_package "$fixture" "v4.0.4b39" FAKE_SPARKLE_KEY_MISMATCH=1
assert_no_release "$fixture"

for zip_mode in corrupt truncated extra; do
    fixture="$(make_fixture "$zip_mode-zip")"
    if [[ "$zip_mode" == "extra" ]]; then
        expect_failure "release ZIP contains an unexpected entry" run_package "$fixture" "v4.0.4b39" FAKE_ZIP_MODE="$zip_mode"
    else
        expect_failure "release ZIP integrity check failed" run_package "$fixture" "v4.0.4b39" FAKE_ZIP_MODE="$zip_mode"
    fi
    assert_no_release "$fixture"
done

fixture="$(make_fixture unsafe-zip-symlink)"
expect_failure "release ZIP contains an unsafe symbolic link" run_package "$fixture" "v4.0.4b39" FAKE_UNSAFE_APP_SYMLINK=1
assert_no_release "$fixture"

outside_product="$test_root/outside-product"
mkdir "$outside_product"
fixture="$(make_fixture product-symlink)"
ln -s "$outside_product" "$fixture/Product"
expect_failure "Product output directory must not be a symbolic link" run_package "$fixture" "v4.0.4b39"
[[ -z "$(find "$outside_product" -mindepth 1 -print -quit)" ]] || fail "Product symlink escaped outside the repository"

outside_release="$test_root/outside-release"
mkdir "$outside_release"
fixture="$(make_fixture destination-symlink)"
mkdir "$fixture/Product"
ln -s "$outside_release" "$fixture/Product/v4.0.4b39"
expect_failure "release destination already exists or is a symbolic link" run_package "$fixture" "v4.0.4b39"
[[ -z "$(find "$outside_release" -mindepth 1 -print -quit)" ]] || fail "Release destination symlink was modified"

fixture="$(make_fixture dangling-destination-symlink)"
mkdir "$fixture/Product"
ln -s "$test_root/does-not-exist" "$fixture/Product/v4.0.4b39"
expect_failure "release destination already exists or is a symbolic link" run_package "$fixture" "v4.0.4b39"
[[ -L "$fixture/Product/v4.0.4b39" ]] || fail "Dangling caller output symlink was removed"

fixture="$(make_fixture existing-release)"
mkdir -p "$fixture/Product/v4.0.4b39"
printf 'caller output\n' > "$fixture/Product/v4.0.4b39/sentinel"
expect_failure "release destination already exists or is a symbolic link" run_package "$fixture" "v4.0.4b39"
[[ "$(<"$fixture/Product/v4.0.4b39/sentinel")" == "caller output" ]] || fail "Existing caller output was modified"

fixture="$(make_fixture failed-publication)"
expect_failure "failed to publish complete release directory" run_package "$fixture" "v4.0.4b39" FAKE_PUBLISH_FAIL=1
assert_no_release "$fixture"

fixture="$(make_fixture publication-race)"
expect_failure "release destination changed during atomic publication" run_package "$fixture" "v4.0.4b39" FAKE_PUBLISH_RACE=1
[[ "$(<"$fixture/Product/v4.0.4b39/sentinel")" == "caller sentinel" ]] || fail "Publication race removed caller destination"
[[ -z "$(find "$fixture/Product/v4.0.4b39" -maxdepth 1 -name '.v4.0.4b39.staging.*' -print -quit)" ]] || \
    fail "Publication race left owned nested staging"
[[ ! -e "$fixture/Product/v4.0.4b39/Xcodes.zip" ]] || fail "Publication race left partial release output"

fixture="$(make_fixture release-lock-contention)"
mkdir -p "$fixture/Product/.release-locks/v4.0.4b39"
printf 'first publisher\n' > "$fixture/Product/.release-locks/v4.0.4b39/sentinel"
expect_failure "release lock is already held" run_package "$fixture" "v4.0.4b39"
[[ "$(<"$fixture/Product/.release-locks/v4.0.4b39/sentinel")" == "first publisher" ]] || fail "Contending publisher removed existing lock"
assert_no_release "$fixture"

fixture="$(make_fixture failed-published-checksum)"
expect_failure "published ZIP checksum changed" run_package "$fixture" "v4.0.4b39" FAKE_PUBLISHED_CORRUPT=1
assert_no_release "$fixture"

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

mutate_notary() {
    local name="$1"
    local mutation="$2"
    local fixture
    local mutated_script

    fixture="$(make_fixture "notary-$name")"
    mutated_script="$fixture/Scripts/notarize-mutated.sh"
    cp "$fixture/Scripts/notarize.sh" "$mutated_script"
    perl -0pi -e "$mutation" "$mutated_script"
    printf 'caller archive\n' > "$fixture/caller.zip"
    expect_failure "notarytool submission failed" env \
        XCRUN_TOOL="$fixture/bin/xcrun" \
        PLUTIL_TOOL=/usr/bin/plutil \
        NOTARY_KEY_ID=TESTKEY123 \
        NOTARY_ISSUER_ID=00000000-0000-0000-0000-000000000000 \
        NOTARY_KEY_PATH="$fixture/notary-key.p8" \
        FAKE_TOOL_LOG="$fixture/tool.log" \
        bash "$mutated_script" "$fixture/caller.zip"
}

mutate_notary missing_archive 's/submit "\$archive_path" \\\n/submit \\\n/'
mutate_notary missing_key 's/    --key "\$notary_key_path" \\\n//'
mutate_notary missing_key_id 's/    --key-id "\$notary_key_id" \\\n//'
mutate_notary missing_issuer 's/    --issuer "\$notary_issuer_id" \\\n//'
mutate_notary missing_wait 's/    --wait \\\n//'

fixture="$(make_fixture successful-flow)"
run_package "$fixture" "v4.0.4b39" > "$test_root/success.log"
release_dir="$fixture/Product/v4.0.4b39"
for output in Xcodes.zip Xcodes.zip.sha256 sparkle-signature.txt release-manifest.txt; do
    [[ -f "$release_dir/$output" && ! -L "$release_dir/$output" && -s "$release_dir/$output" ]] || \
        fail "Successful flow omitted regular release file $output"
done
grep -Fq 'tag=v4.0.4b39' "$release_dir/release-manifest.txt" || fail "Manifest omitted release tag"
grep -Fq 'version=4.0.4' "$release_dir/release-manifest.txt" || fail "Manifest omitted marketing version"
grep -Fq 'build=39' "$release_dir/release-manifest.txt" || fail "Manifest omitted build version"
grep -Fq 'team_id=K2648T24P4' "$release_dir/release-manifest.txt" || fail "Manifest omitted release team"
/usr/bin/unzip -tq "$release_dir/Xcodes.zip" >/dev/null || fail "Published release ZIP is invalid"
published_checksum="$(/usr/bin/shasum -a 256 "$release_dir/Xcodes.zip" | awk '{ print $1 }')"
grep -Fxq "$published_checksum  Xcodes.zip" "$release_dir/Xcodes.zip.sha256" || fail "Published checksum does not match ZIP"
grep -Fq "xcrun notarytool submit" "$fixture/tool.log" || fail "Notary submit was not recorded"
grep -Fq " --key $fixture/notary-key.p8 --key-id TESTKEY123 --issuer 00000000-0000-0000-0000-000000000000 --wait --output-format json" "$fixture/tool.log" || fail "Notary submit authentication contract changed"
grep -Fq "generate_appcast --ed-key-file $fixture/sparkle-key" "$fixture/tool.log" || fail "Sparkle key correspondence was not verified"
[[ ! -e "$fixture/Product/.release-locks/v4.0.4b39" ]] || fail "Successful release left its per-tag lock"
[[ "$(<"$fixture/Xcodes/Resources/Licenses.rtf")" == "committed licence" ]] || fail "Release build left generated licences in tracked source"
expect_failure "release destination already exists or is a symbolic link" run_package "$fixture" "v4.0.4b39"

printf 'Release script contracts passed.\n'
