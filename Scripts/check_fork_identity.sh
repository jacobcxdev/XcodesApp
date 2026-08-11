#!/bin/bash

set -euo pipefail

repo_root=""
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly repo_root
readonly project="$repo_root/Xcodes.xcodeproj"
readonly project_file="$project/project.pbxproj"
readonly shared_constants="$repo_root/HelperXPCShared/HelperXPCShared.swift"
readonly helper_dir="$repo_root/dev.jacobcx.Xcodes.Helper"
readonly helper_info_plist="$helper_dir/Info.plist"
readonly launchd_plist="$helper_dir/launchd.plist"
readonly uninstall_script="$repo_root/Scripts/uninstall_privileged_helper.sh"
readonly app_info_plist="$repo_root/Xcodes/Resources/Info.plist"
readonly helper_scheme="$project/xcshareddata/xcschemes/dev.jacobcx.Xcodes.Helper.xcscheme"
readonly readme="$repo_root/README.md"
readonly contributing="$repo_root/CONTRIBUTING.md"
readonly license="$repo_root/LICENSE"
readonly forking="$repo_root/FORKING.md"
readonly codeowners="$repo_root/.github/CODEOWNERS"
readonly bug_template="$repo_root/.github/ISSUE_TEMPLATE/bug_report.md"
readonly feature_template="$repo_root/.github/ISSUE_TEMPLATE/feature_request.md"
readonly release_drafter="$repo_root/.github/release-drafter.yml"
readonly app_source="$repo_root/Xcodes/XcodesApp.swift"
readonly about_source="$repo_root/Xcodes/Frontend/About/AboutView.swift"
readonly bottom_status_source="$repo_root/Xcodes/Frontend/XcodeList/BottomStatusBar.swift"
readonly updates_source="$repo_root/Xcodes/Frontend/Preferences/UpdatesPreferencePane.swift"
readonly appcast_config="$repo_root/AppCast/_config.yml"
readonly appcast_template="$repo_root/AppCast/_includes/appcast.inc"
readonly appcast_filter="$repo_root/AppCast/_plugins/signature_filter.rb"
readonly appcast_test="$repo_root/AppCast/test_appcast.rb"
readonly appcast_workflow="$repo_root/.github/workflows/appcast.yml"
readonly appcast_identity_check="$repo_root/Scripts/check_appcast_identity.sh"
readonly appcast_workflow_check="$repo_root/Scripts/check_appcast_workflow.rb"
readonly ci_workflow="$repo_root/.github/workflows/ci.yml"
readonly release_workflow="$repo_root/.github/workflows/release.yml"
readonly ci_release_workflow_check="$repo_root/Scripts/check_ci_release_workflows.rb"
readonly release_documentation="$repo_root/docs/RELEASING.md"

readonly app_id="dev.jacobcx.Xcodes"
readonly tests_id="dev.jacobcx.Xcodes.Tests"
readonly helper_id="dev.jacobcx.Xcodes.Helper"
readonly team_id="K2648T24P4"
# shellcheck disable=SC2016 # Xcode expands this build-setting literal, not the shell.
readonly app_requirement='identifier "dev.jacobcx.Xcodes" and info [CFBundleShortVersionString] >= "1.0.0" and anchor apple generic and certificate leaf[subject.OU] = "$(CODE_SIGNING_SUBJECT_ORGANIZATIONAL_UNIT)"'
# shellcheck disable=SC2016 # Xcode expands this build-setting literal, not the shell.
readonly helper_requirement='identifier "dev.jacobcx.Xcodes.Helper" and info [CFBundleShortVersionString] >= "1.0.0" and anchor apple generic and certificate leaf[subject.OU] = "$(CODE_SIGNING_SUBJECT_ORGANIZATIONAL_UNIT)"'

status=0

fail() {
    echo "$1" >&2
    status=1
}

require_file() {
    local file="$1"

    if [[ ! -f "$file" ]]; then
        fail "Missing required identity file: ${file#"$repo_root/"}"
    fi
}

require_only_line() {
    local prefix="$1"
    local expected="$2"
    local file="$3"
    local matching_count
    local expected_count

    matching_count=$(awk -v prefix="$prefix" 'index($0, prefix) == 1 { count++ } END { print count + 0 }' "$file")
    expected_count=$(grep -Fxc -- "$expected" "$file" || true)
    if [[ "$matching_count" -ne 1 || "$expected_count" -ne 1 ]]; then
        fail "Unexpected identity assignment for '$prefix' in ${file#"$repo_root/"}"
    fi
}

require_literal() {
    local literal="$1"
    local file="$2"

    if [[ ! -f "$file" ]]; then
        return
    fi

    if ! grep -Fq -- "$literal" "$file"; then
        fail "Missing fork ownership text '$literal' in ${file#"$repo_root/"}"
    fi
}

require_trimmed_line() {
    local expected="$1"
    local file="$2"
    local count

    count=$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' "$file" | grep -Fxc -- "$expected" || true)
    if [[ "$count" -ne 1 ]]; then
        fail "Expected one exact fork ownership line '$expected' in ${file#"$repo_root/"}"
    fi
}

for required_file in \
    "$project_file" \
    "$shared_constants" \
    "$helper_info_plist" \
    "$launchd_plist" \
    "$uninstall_script" \
    "$app_info_plist" \
    "$helper_scheme" \
    "$updates_source" \
    "$appcast_config" \
    "$appcast_template" \
    "$appcast_filter" \
    "$appcast_test" \
    "$appcast_workflow" \
    "$appcast_identity_check" \
    "$appcast_workflow_check" \
    "$ci_workflow" \
    "$release_workflow" \
    "$ci_release_workflow_check" \
    "$release_documentation"; do
    require_file "$required_file"
done

if [[ ! -d "$helper_dir" ]]; then
    fail "Missing renamed helper directory: ${helper_dir#"$repo_root/"}"
fi

if [[ "$status" -ne 0 ]]; then
    exit "$status"
fi

for ownership_file in \
    "$readme" \
    "$contributing" \
    "$license" \
    "$forking" \
    "$codeowners" \
    "$bug_template" \
    "$feature_template" \
    "$release_drafter" \
    "$app_source" \
    "$about_source" \
    "$bottom_status_source"; do
    require_file "$ownership_file"
done

require_literal "maintained fork" "$readme"
require_literal "https://github.com/XcodesOrg/XcodesApp" "$readme"
require_literal "git clone https://github.com/jacobcxdev/XcodesApp.git" "$readme"
require_literal "https://github.com/jacobcxdev/XcodesApp/releases/latest" "$readme"
require_literal "https://github.com/jacobcxdev/XcodesApp/issues" "$contributing"
require_literal "upstream/<topic>" "$contributing"
require_literal "jacobcxdev/<topic>" "$contributing"
require_trimmed_line 'let xcodesRepoURL = URL(string: "https://github.com/jacobcxdev/XcodesApp/")!' "$app_source"
require_trimmed_line 'let bugReportURL = URL(string: "https://github.com/jacobcxdev/XcodesApp/issues/new?assignees=&labels=bug&template=bug_report.md&title=")!' "$app_source"
require_trimmed_line 'let featureRequestURL = URL(string: "https://github.com/jacobcxdev/XcodesApp/issues/new?assignees=&labels=enhancement&template=feature_request.md&title=")!' "$app_source"
require_trimmed_line 'openURL(URL(string: "https://github.com/jacobcxdev/XcodesApp/")!)' "$about_source"
require_literal "https://github.com/jacobcxdev/XcodesApp#installation" "$release_drafter"
require_literal "https://github.com/jacobcxdev/XcodesApp/releases/latest" "$bug_template"
require_literal "https://github.com/jacobcxdev/XcodesApp/issues" "$feature_template"
require_literal "*   @jacobcxdev" "$codeowners"
require_literal "Copyright (c) 2026 Jacob Clayden" "$license"
require_literal "docs/RELEASING.md" "$readme"
require_literal "DEVELOPER_ID_APPLICATION_P12_BASE64" "$release_documentation"
require_literal "v4.0.4b44" "$release_documentation"

for contributor in \
    '@dompepin' \
    '@gualtierofrigerio' \
    '@cesartru88' \
    '@ryan-son' \
    '@alexmazlov' \
    '@egesucu' \
    '@KGurpreet' \
    '@megabitsenmzq' \
    '@marcusziade' \
    '@itszero' \
    '@gelosi' \
    '@tatsuz0u' \
    '@drct' \
    '@jfversluis' \
    '@brunomunizaf' \
    '@jakex7' \
    '@ferranabello' \
    '@alladinian' \
    '@neetrath'; do
    require_literal "$contributor" "$readme"
done

if [[ -f "$forking" ]]; then
    for command in \
        'git remote add upstream https://github.com/XcodesOrg/XcodesApp.git' \
        'git remote set-url --push upstream DISABLED' \
        'git fetch upstream' \
        'git switch --create upstream/<topic> upstream/main' \
        'git push --set-upstream origin upstream/<topic>' \
        'git switch --create sync/upstream-YYYYMMDD origin/main' \
        'git merge --no-ff upstream/main'; do
        require_literal "$command" "$forking"
    done
fi

if grep -R -n -i -E -- \
    'github\.com/(XcodesOrg|RobotsAndPencils)/XcodesApp|github\.com/robotsandpencils/xcodesapp|opencollective\.com/xcodesapp' \
    "$codeowners" "$bug_template" "$feature_template" \
    "$release_drafter" "$app_source" "$about_source" "$bottom_status_source"; then
    fail "Upstream-owned operational link remains in fork-facing metadata"
fi

if grep -n -E -- 'Support\.Xcodes|heart\.circle|opencollective\.com/xcodesapp|github\.com/jacobcxdev/XcodesApp/issues' \
    "$about_source" "$bottom_status_source"; then
    fail "Donation-labelled support control remains without a fork donation destination"
fi

if grep -n -i -E -- \
    'github\.com/XcodesOrg/XcodesApp/(issues|pulls|releases)|github\.com/robotsandpencils/xcodesapp|opencollective\.com/xcodesapp' \
    "$contributing"; then
    fail "Upstream-owned fork support link remains in CONTRIBUTING.md"
fi

if grep -n -i -E -- \
    'github\.com/XcodesOrg/XcodesApp/(releases|workflows|issues)|XcodesOrg/homebrew-cask|opencollective\.com/xcodesapp|twitter\.com/xcodesApp|iosdev\.space/@XcodesApp' \
    "$readme"; then
    fail "Unsupported upstream release, package, collective, or social claim remains in README.md"
fi

if ! "$appcast_identity_check" "$repo_root"; then
    fail "Appcast identity contract failed"
fi

require_only_line 'let machServiceName = ' "let machServiceName = \"$helper_id\"" "$shared_constants"
require_only_line 'let clientBundleID = ' "let clientBundleID = \"$app_id\"" "$shared_constants"
require_only_line 'PRIVILEGED_HELPER_LABEL=' "PRIVILEGED_HELPER_LABEL=$helper_id" "$uninstall_script"

if ! project_description=$(xcodebuild -list -json -project "$project"); then
    fail "Unable to read Xcode project identity"
elif ! jq -e \
    --arg app_target "Xcodes" \
    --arg tests_target "XcodesTests" \
    --arg helper_target "$helper_id" \
    '(.project.targets | sort) == ([$app_target, $tests_target, $helper_target] | sort)
        and (.project.configurations | length > 0)
        and (.project.schemes | index($app_target) != null)
        and (.project.schemes | index($helper_target) != null)' \
    <<< "$project_description" >/dev/null; then
    fail "Unexpected Xcode project targets, configurations, or schemes"
fi

if [[ "$status" -eq 0 ]]; then
    while IFS= read -r configuration; do
        if ! settings=$(xcodebuild -project "$project" -alltargets -configuration "$configuration" -showBuildSettings -json); then
            fail "Unable to resolve build settings for configuration '$configuration'"
            continue
        fi

        if ! jq -e \
            --arg app_target "Xcodes" \
            --arg tests_target "XcodesTests" \
            --arg helper_target "$helper_id" \
            --arg app_id "$app_id" \
            --arg tests_id "$tests_id" \
            --arg helper_id "$helper_id" \
            --arg team_id "$team_id" \
            '([.[].target] | unique | sort) == ([$app_target, $tests_target, $helper_target] | sort)
                and all(.[].buildSettings; .DEVELOPMENT_TEAM == $team_id
                    and .CODE_SIGNING_SUBJECT_ORGANIZATIONAL_UNIT == $team_id)
                and all(.[];
                    if .target == $app_target then
                        .buildSettings.PRODUCT_BUNDLE_IDENTIFIER == $app_id
                            and .buildSettings.FULL_PRODUCT_NAME == "Xcodes.app"
                    elif .target == $tests_target then
                        .buildSettings.PRODUCT_BUNDLE_IDENTIFIER == $tests_id
                            and .buildSettings.FULL_PRODUCT_NAME == "XcodesTests.xctest"
                    elif .target == $helper_target then
                        .buildSettings.PRODUCT_BUNDLE_IDENTIFIER == $helper_id
                            and .buildSettings.FULL_PRODUCT_NAME == $helper_id
                    else false
                    end)' <<< "$settings" >/dev/null; then
            echo "$settings" | jq -r \
                --arg configuration "$configuration" \
                '.[] | [$configuration, .target, .buildSettings.PRODUCT_BUNDLE_IDENTIFIER,
                    (.buildSettings.DEVELOPMENT_TEAM // "<missing>"), .buildSettings.FULL_PRODUCT_NAME] | @tsv' >&2
            fail "Unexpected resolved identity in configuration '$configuration'"
        fi
    done < <(jq -r '.project.configurations[]' <<< "$project_description")
fi

if ! helper_info=$(plutil -convert json -o - "$helper_info_plist"); then
    fail "Unable to parse helper Info.plist"
elif ! jq -e --arg requirement "$app_requirement" \
    '.SMAuthorizedClients == [$requirement]' <<< "$helper_info" >/dev/null; then
    fail "Unexpected helper authorised-client requirement"
fi

if ! app_info=$(plutil -convert json -o - "$app_info_plist"); then
    fail "Unable to parse app Info.plist"
elif ! jq -e --arg helper_id "$helper_id" --arg requirement "$helper_requirement" \
    '.SMPrivilegedExecutables == {($helper_id): $requirement}' <<< "$app_info" >/dev/null; then
    fail "Unexpected app privileged-helper requirement"
fi

if ! jq -e '.NSHumanReadableCopyright == "Copyright © 2026 Jacob Clayden"' \
    <<< "$app_info" >/dev/null; then
    fail "Unexpected app copyright"
fi

if ! launchd_info=$(plutil -convert json -o - "$launchd_plist"); then
    fail "Unable to parse helper launchd plist"
elif ! jq -e --arg helper_id "$helper_id" \
    '.Label == $helper_id and .MachServices == {($helper_id): true}' <<< "$launchd_info" >/dev/null; then
    fail "Unexpected helper launchd identity"
fi

if [[ "$(xmllint --xpath 'count(//BuildableReference)' "$helper_scheme")" != "3" ]] \
    || [[ "$(xmllint --xpath "count(//BuildableReference[not(@BuildableName='$helper_id')])" "$helper_scheme")" != "0" ]] \
    || [[ "$(xmllint --xpath "count(//BuildableReference[not(@BlueprintName='$helper_id')])" "$helper_scheme")" != "0" ]]; then
    fail "Unexpected helper scheme identity"
fi

if [[ -d "$repo_root/com.xcodesorg.xcodesapp.Helper" ]]; then
    fail "Legacy helper directory still exists: com.xcodesorg.xcodesapp.Helper"
fi

if [[ -f "$project/xcshareddata/xcschemes/com.robotsandpencils.XcodesApp.Helper.xcscheme" ]]; then
    fail "Legacy helper scheme still exists: com.robotsandpencils.XcodesApp.Helper.xcscheme"
fi

identity_scope=(
    "$project"
    "$repo_root/HelperXPCShared"
    "$helper_dir"
    "$uninstall_script"
    "$app_info_plist"
)

if grep -R -n -E -- 'com\.xcodesorg\.xcodesapp|com\.robotsandpencils\.XcodesApp|ZU6GR6B2FY' "${identity_scope[@]}"; then
    fail "Legacy operational identities remain"
else
    scan_status=$?
    if [[ "$scan_status" -ne 1 ]]; then
        fail "Unable to scan the complete operational identity scope"
    fi
fi

if [[ "$status" -ne 0 ]]; then
    exit "$status"
fi

if ! ruby "$ci_release_workflow_check"; then
    fail "CI and release workflow identity check failed"
fi

if [[ "$status" -ne 0 ]]; then
    exit "$status"
fi

echo "Fork identity check passed"
