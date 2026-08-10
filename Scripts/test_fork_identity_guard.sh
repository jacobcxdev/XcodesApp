#!/bin/bash

set -euo pipefail

readonly repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly test_root="$(mktemp -d "${TMPDIR:-/tmp}/xcodes-fork-identity-test.XXXXXX")"
readonly fixture_root="$test_root/repo"

cleanup() {
    rm -r -- "$test_root"
}
trap cleanup EXIT

mkdir -p \
    "$fixture_root/.github/ISSUE_TEMPLATE" \
    "$fixture_root/.github/workflows" \
    "$fixture_root/AppCast/_includes" \
    "$fixture_root/AppCast/_plugins" \
    "$fixture_root/Xcodes/Frontend/About" \
    "$fixture_root/Xcodes/Frontend/Preferences" \
    "$fixture_root/Xcodes/Frontend/XcodeList" \
    "$fixture_root/Xcodes/Resources" \
    "$fixture_root/Scripts"
cp -R \
    "$repo_root/Xcodes.xcodeproj" \
    "$repo_root/HelperXPCShared" \
    "$repo_root/dev.jacobcx.Xcodes.Helper" \
    "$fixture_root/"
cp \
    "$repo_root/Scripts/check_appcast_identity.sh" \
    "$repo_root/Scripts/check_appcast_workflow.rb" \
    "$repo_root/Scripts/check_fork_identity.sh" \
    "$repo_root/Scripts/uninstall_privileged_helper.sh" \
    "$fixture_root/Scripts/"
cp \
    "$repo_root/README.md" \
    "$repo_root/CONTRIBUTING.md" \
    "$repo_root/LICENSE" \
    "$repo_root/FORKING.md" \
    "$fixture_root/"
cp \
    "$repo_root/.github/CODEOWNERS" \
    "$repo_root/.github/release-drafter.yml" \
    "$fixture_root/.github/"
cp \
    "$repo_root/.github/ISSUE_TEMPLATE/bug_report.md" \
    "$repo_root/.github/ISSUE_TEMPLATE/feature_request.md" \
    "$fixture_root/.github/ISSUE_TEMPLATE/"
cp "$repo_root/.github/workflows/appcast.yml" "$fixture_root/.github/workflows/"
cp \
    "$repo_root/AppCast/_config.yml" \
    "$repo_root/AppCast/Gemfile.lock" \
    "$repo_root/AppCast/test_appcast.rb" \
    "$fixture_root/AppCast/"
cp "$repo_root/AppCast/_includes/appcast.inc" "$fixture_root/AppCast/_includes/"
cp "$repo_root/AppCast/_plugins/signature_filter.rb" "$fixture_root/AppCast/_plugins/"
cp "$repo_root/Xcodes/XcodesApp.swift" "$fixture_root/Xcodes/"
cp "$repo_root/Xcodes/Frontend/About/AboutView.swift" "$fixture_root/Xcodes/Frontend/About/"
cp \
    "$repo_root/Xcodes/Frontend/Preferences/UpdatesPreferencePane.swift" \
    "$fixture_root/Xcodes/Frontend/Preferences/"
cp \
    "$repo_root/Xcodes/Frontend/XcodeList/BottomStatusBar.swift" \
    "$fixture_root/Xcodes/Frontend/XcodeList/"
cp "$repo_root/Xcodes/Resources/Info.plist" "$fixture_root/Xcodes/Resources/Info.plist"

"$fixture_root/Scripts/check_fork_identity.sh" >/dev/null

perl -0pi -e \
    's/PRODUCT_BUNDLE_IDENTIFIER = dev\.jacobcx\.Xcodes;/PRODUCT_BUNDLE_IDENTIFIER = unexpected.example.Xcodes;/' \
    "$fixture_root/Xcodes.xcodeproj/project.pbxproj"

if "$fixture_root/Scripts/check_fork_identity.sh" >/dev/null 2>&1; then
    echo "Identity guard accepted a mutated build configuration" >&2
    exit 1
fi

cp \
    "$repo_root/Xcodes.xcodeproj/project.pbxproj" \
    "$fixture_root/Xcodes.xcodeproj/project.pbxproj"
perl -0pi -e \
    's#https://jacobcxdev\.github\.io/XcodesApp/appcast\.xml#https://www.xcodes.app/appcast.xml#g' \
    "$fixture_root/Xcodes/Resources/Info.plist" \
    "$fixture_root/Xcodes/Frontend/Preferences/UpdatesPreferencePane.swift"

if "$fixture_root/Scripts/check_fork_identity.sh" >/dev/null 2>&1; then
    echo "Identity guard accepted a mutated Sparkle feed" >&2
    exit 1
fi

echo "Fork identity guard mutation test passed"
