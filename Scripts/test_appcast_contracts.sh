#!/bin/bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly repo_root
test_root="$(mktemp -d "${TMPDIR:-/tmp}/xcodes-appcast-contracts.XXXXXX")"
readonly test_root

cleanup() {
    rm -r -- "$test_root"
}
trap cleanup EXIT

expect_failure() {
    local label="$1"
    shift

    if "$@" >/dev/null 2>&1; then
        echo "$label mutation unexpectedly passed" >&2
        exit 1
    fi
}

mutate_workflow() {
    local label="$1"
    local mutation="$2"
    local fixture="$test_root/$label.yml"

    cp "$repo_root/.github/workflows/appcast.yml" "$fixture"
    ruby -ryaml -e "$mutation" "$fixture"
    expect_failure "$label" ruby \
        "$repo_root/Scripts/check_appcast_workflow.rb" \
        "$fixture" \
        "$repo_root/AppCast/Gemfile.lock"
}

"$repo_root/Scripts/check_appcast_identity.sh"
ruby "$repo_root/Scripts/test_appcast_release_validation.rb"
bundle exec --gemfile "$repo_root/AppCast/Gemfile" ruby "$repo_root/AppCast/test_appcast.rb"

mutate_workflow permissions_bypass \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); data["jobs"]["build"]["permissions"]["contents"] = "write"; File.write(path, YAML.dump(data) + "# contents: read\n")'
mutate_workflow top_permissions_bypass \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); data["permissions"]["contents"] = "write"; File.write(path, YAML.dump(data) + "# contents: read\n")'
mutate_workflow trigger_bypass \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); data["on"]["release"]["types"] = ["created"]; File.write(path, YAML.dump(data) + "# types: [published]\n")'
mutate_workflow reusable_input_bypass \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); data["on"]["workflow_call"]["inputs"]["expected_release_tag"]["required"] = false; File.write(path, YAML.dump(data) + "# required: true\n")'
# shellcheck disable=SC2016 # GitHub expression must remain literal in mutation comment.
mutate_workflow concurrency_bypass \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); data["concurrency"]["group"] = "appcast-bypass"; File.write(path, YAML.dump(data) + "# group: appcast-${{ github.repository }}\n")'
mutate_workflow repository_bypass \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); data["jobs"]["deploy"]["if"] = "always()"; File.write(path, YAML.dump(data) + "# if: github.repository == jacobcxdev/XcodesApp\n")'
mutate_workflow release_verification_bypass \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); data["jobs"]["build"]["steps"].reject! { |item| item["name"] == "Validate expected published release" }; File.write(path, YAML.dump(data) + "# gh api expected release\n")'
mutate_workflow release_verification_continue_on_error \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); data["jobs"]["build"]["steps"].find { |item| item["name"] == "Validate expected published release" }["continue-on-error"] = true; File.write(path, YAML.dump(data))'
mutate_workflow release_verification_if_false \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); data["jobs"]["build"]["steps"].find { |item| item["name"] == "Validate expected published release" }["if"] = false; File.write(path, YAML.dump(data))'
mutate_workflow release_extra_asset_bypass \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); step = data["jobs"]["build"]["steps"].find { |item| item["name"] == "Validate expected published release" }; step["run"].sub!(/\(\(\[\.assets\[\]\.name\] \| sort\) == \(\[.*?\] \| sort\)\) and/m, "(([\"Xcodes.zip\", \"Xcodes.zip.sha256\", \"release-manifest.txt\", \"sparkle-signature.txt\"] - [.assets[].name]) | length == 0) and"); File.write(path, YAML.dump(data) + "# exact release asset set\n")'
mutate_workflow release_asset_size_bypass \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); step = data["jobs"]["build"]["steps"].find { |item| item["name"] == "Validate expected published release" }; step["run"].sub!(/^\s*\(all\(\.assets\[\];.*?\)\) and\n/m, ""); File.write(path, YAML.dump(data) + "# every asset size > 0\n")'
mutate_workflow release_sole_zip_bypass \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); step = data["jobs"]["build"]["steps"].find { |item| item["name"] == "Validate expected published release" }; step["run"].sub!(/\(\[\n\s*\.assets\[\].*?\] == \["Xcodes\.zip"\]\)/m, "true"); File.write(path, YAML.dump(data) + "# Xcodes.zip is sole ZIP\n")'
mutate_workflow deploy_bypass \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); step = data["jobs"]["deploy"]["steps"].find { |item| item["uses"]&.start_with?("JamesIves/") }; step["with"]["branch"] = "main"; File.write(path, YAML.dump(data) + "# branch: gh-pages\n")'
mutate_workflow action_pin_bypass \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); data["jobs"]["build"]["steps"].find { |item| item["uses"]&.start_with?("actions/checkout@") }["uses"] = "actions/checkout@v4"; File.write(path, YAML.dump(data) + "# actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683\n")'
mutate_workflow validation_bypass \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); data["jobs"]["build"]["steps"].reject! { |item| item["name"] == "Validate rendered appcasts" }; File.write(path, YAML.dump(data) + "# xmllint --noout AppCast/_site/appcast.xml AppCast/_site/appcast_pre.xml\n")'
mutate_workflow validation_continue_on_error \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); data["jobs"]["build"]["steps"].find { |item| item["name"] == "Validate rendered appcasts" }["continue-on-error"] = true; File.write(path, YAML.dump(data))'
mutate_workflow validation_if_false \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); data["jobs"]["build"]["steps"].find { |item| item["name"] == "Validate rendered appcasts" }["if"] = false; File.write(path, YAML.dump(data))'
mutate_workflow fixture_continue_on_error \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); data["jobs"]["build"]["steps"].find { |item| item["name"] == "Test appcast generation" }["continue-on-error"] = true; File.write(path, YAML.dump(data))'
mutate_workflow upload_if_false \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); data["jobs"]["build"]["steps"].find { |item| item["name"] == "Upload verified appcasts" }["if"] = false; File.write(path, YAML.dump(data))'

identity_fixture="$test_root/identity"
mkdir -p \
    "$identity_fixture/.github/workflows" \
    "$identity_fixture/Scripts" \
    "$identity_fixture/Xcodes/Frontend/Preferences" \
    "$identity_fixture/Xcodes/Resources"
cp -R "$repo_root/AppCast" "$identity_fixture/"
cp "$repo_root/.github/workflows/appcast.yml" "$identity_fixture/.github/workflows/"
cp \
    "$repo_root/Scripts/check_appcast_identity.sh" \
    "$repo_root/Scripts/check_appcast_workflow.rb" \
    "$identity_fixture/Scripts/"
cp "$repo_root/Xcodes/Frontend/Preferences/UpdatesPreferencePane.swift" "$identity_fixture/Xcodes/Frontend/Preferences/"
cp "$repo_root/Xcodes/Resources/Info.plist" "$identity_fixture/Xcodes/Resources/"

plutil -replace SUPublicEDKey -string "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" \
    "$identity_fixture/Xcodes/Resources/Info.plist"
perl -0pi -e \
    's#</plist>#<!-- CbToeJaT+HbP9oQAtNtKtBABQhYYisM4Y/fI8q2gcF8= -->\n</plist>#' \
    "$identity_fixture/Xcodes/Resources/Info.plist"
expect_failure public_key "$identity_fixture/Scripts/check_appcast_identity.sh" "$identity_fixture"
cp "$repo_root/Xcodes/Resources/Info.plist" "$identity_fixture/Xcodes/Resources/Info.plist"

perl -0pi -e \
    's#static let prereleaseAppcast = "https://jacobcxdev\.github\.io/XcodesApp/appcast_pre\.xml"#static let prereleaseAppcast = "https://example.invalid/appcast_pre.xml"\n    // static let prereleaseAppcast = "https://jacobcxdev.github.io/XcodesApp/appcast_pre.xml"#' \
    "$identity_fixture/Xcodes/Frontend/Preferences/UpdatesPreferencePane.swift"
expect_failure prerelease_feed "$identity_fixture/Scripts/check_appcast_identity.sh" "$identity_fixture"

template_fixture="$test_root/template"
cp -R "$repo_root/AppCast" "$template_fixture"
perl -0pi -e \
    's/if asset.name == "Xcodes.zip"/if asset.name == "wrong.zip"\n                        {% comment %} if asset.name == "Xcodes.zip" {% endcomment %}/' \
    "$template_fixture/_includes/appcast.inc"
expect_failure zip_selector env APPCAST_SOURCE="$template_fixture" \
    bundle exec --gemfile "$repo_root/AppCast/Gemfile" ruby "$repo_root/AppCast/test_appcast.rb"

echo "Appcast contract mutation tests passed"
