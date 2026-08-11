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
bash "$repo_root/Scripts/test_appcast_history_validation.sh"
bundle exec --gemfile "$repo_root/AppCast/Gemfile" ruby "$repo_root/AppCast/test_appcast.rb"

mutate_workflow permissions_bypass \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); data["jobs"]["build"]["permissions"]["contents"] = "write"; File.write(path, YAML.dump(data) + "# contents: read\n")'
mutate_workflow top_permissions_bypass \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); data["permissions"]["contents"] = "write"; File.write(path, YAML.dump(data) + "# contents: read\n")'
mutate_workflow trigger_bypass \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); data["on"]["release"]["types"] = ["created"]; File.write(path, YAML.dump(data) + "# types: [published]\n")'
mutate_workflow reusable_input_bypass \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); data["on"]["workflow_call"]["inputs"]["tag"]["required"] = false; File.write(path, YAML.dump(data) + "# required: true\n")'
mutate_workflow reusable_secret_bypass \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); data["on"]["workflow_call"]["secrets"]["INDEX_REPO_TOKEN"]["required"] = false; File.write(path, YAML.dump(data) + "# required: true\n")'
# shellcheck disable=SC2016 # GitHub expression must remain literal in mutation comment.
mutate_workflow concurrency_bypass \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); data["concurrency"]["group"] = "appcast-${{ inputs.tag || github.event.release.tag_name }}"; File.write(path, YAML.dump(data) + "# one repository-wide group\n")'
mutate_workflow cancelling_concurrency \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); data["concurrency"]["cancel-in-progress"] = true; File.write(path, YAML.dump(data) + "# cancel-in-progress: false\n")'
mutate_workflow missing_build_timeout \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); data["jobs"]["build"].delete("timeout-minutes"); File.write(path, YAML.dump(data) + "# bounded build timeout\n")'
mutate_workflow missing_publish_timeout \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); data["jobs"]["publish"].delete("timeout-minutes"); File.write(path, YAML.dump(data) + "# bounded publish timeout\n")'
mutate_workflow repository_bypass \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); data["jobs"]["publish"]["if"] = "always()"; File.write(path, YAML.dump(data) + "# if: github.repository == jacobcxdev/XcodesApp\n")'
mutate_workflow missing_build_ref_guard \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); data["jobs"]["build"]["if"] = "github.repository == '\''jacobcxdev/XcodesApp'\''"; File.write(path, YAML.dump(data) + "# exact tag ref guard\n")'
mutate_workflow missing_checkout_ref \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); step = data["jobs"]["build"]["steps"].find { |item| item["name"] == "Checkout expected release tag" }; step["with"].delete("ref"); File.write(path, YAML.dump(data) + "# exact expected tag checkout\n")'
mutate_workflow mutable_checkout_ref \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); step = data["jobs"]["build"]["steps"].find { |item| item["name"] == "Checkout expected release tag" }; step["with"]["ref"] = "main"; File.write(path, YAML.dump(data) + "# immutable tag checkout\n")'
mutate_workflow shallow_checkout \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); step = data["jobs"]["build"]["steps"].find { |item| item["name"] == "Checkout expected release tag" }; step["with"]["fetch-depth"] = 1; File.write(path, YAML.dump(data) + "# full tag ancestry\n")'
mutate_workflow missing_source_verification \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); data["jobs"]["build"]["steps"].reject! { |item| item["name"] == "Verify immutable appcast source" }; File.write(path, YAML.dump(data) + "# source authority step\n")'
mutate_workflow missing_source_ref_check \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); step = data["jobs"]["build"]["steps"].find { |item| item["name"] == "Verify immutable appcast source" }; step["run"].sub!(/^.*GITHUB_REF.*\n/, ""); File.write(path, YAML.dump(data) + "# exact workflow tag ref\n")'
mutate_workflow missing_source_tag_check \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); step = data["jobs"]["build"]["steps"].find { |item| item["name"] == "Verify immutable appcast source" }; step["run"].sub!(/^.*Appcast tag does not point.*\n/, ""); File.write(path, YAML.dump(data) + "# peeled tag commit match\n")'
mutate_workflow missing_source_ancestry \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); step = data["jobs"]["build"]["steps"].find { |item| item["name"] == "Verify immutable appcast source" }; step["run"].sub!(/^.*merge-base --is-ancestor.*\n/, ""); File.write(path, YAML.dump(data) + "# origin main ancestry\n")'
mutate_workflow source_verification_continue_on_error \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); step = data["jobs"]["build"]["steps"].find { |item| item["name"] == "Verify immutable appcast source" }; step["continue-on-error"] = true; File.write(path, YAML.dump(data))'
mutate_workflow source_verification_if_false \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); step = data["jobs"]["build"]["steps"].find { |item| item["name"] == "Verify immutable appcast source" }; step["if"] = false; File.write(path, YAML.dump(data))'
mutate_workflow release_verification_bypass \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); data["jobs"]["build"]["steps"].reject! { |item| item["name"] == "Validate complete published release history" }; File.write(path, YAML.dump(data) + "# complete release history validation\n")'
mutate_workflow release_verification_continue_on_error \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); data["jobs"]["build"]["steps"].find { |item| item["name"] == "Validate complete published release history" }["continue-on-error"] = true; File.write(path, YAML.dump(data))'
mutate_workflow release_verification_if_false \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); data["jobs"]["build"]["steps"].find { |item| item["name"] == "Validate complete published release history" }["if"] = false; File.write(path, YAML.dump(data))'
# shellcheck disable=SC2016 # Runtime variables must remain literal in mutation source.
mutate_workflow expected_release_only \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); step = data["jobs"]["build"]["steps"].find { |item| item["name"] == "Validate complete published release history" }; step["run"] = "gh api repos/$GITHUB_REPOSITORY/releases/tags/$EXPECTED_RELEASE_TAG > AppCast/_data/validated_releases.json"; File.write(path, YAML.dump(data) + "# all paginated releases\n")'
mutate_workflow weakened_history_validator \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); step = data["jobs"]["build"]["steps"].find { |item| item["name"] == "Validate complete published release history" }; step["run"].sub!("ruby Scripts/validate_appcast_history.rb", "true # history validator bypassed"); File.write(path, YAML.dump(data) + "# exact history validator\n")'
# shellcheck disable=SC2016 # GitHub expression must remain literal in mutation source.
mutate_workflow raw_api_jekyll_input \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); step = data["jobs"]["build"]["steps"].find { |item| item["name"] == "Build appcasts" }; step["env"] = { "JEKYLL_GITHUB_TOKEN" => "${{ github.token }}" }; File.write(path, YAML.dump(data) + "# sanitized releases only\n")'
# shellcheck disable=SC2016 # Runtime variables must remain literal in mutation source.
mutate_workflow wrong_rendered_release_input \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); step = data["jobs"]["build"]["steps"].find { |item| item["name"] == "Validate rendered appcasts" }; step["run"].sub!("\"$VALIDATED_RELEASES_FILE\"", "raw-releases.json"); File.write(path, YAML.dump(data) + "# sanitized releases exact\n")'
mutate_workflow pages_publish_bypass \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); data["jobs"]["publish"]["permissions"]["contents"] = "write"; data["jobs"]["publish"]["steps"] << { "uses" => "JamesIves/github-pages-deploy-action@fa24774553152dd7873cd16ebd8d959b010c5445" }; File.write(path, YAML.dump(data) + "# central publication only\n")'
mutate_workflow mutable_central_checkout \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); step = data["jobs"]["publish"]["steps"].find { |item| item["name"] == "Checkout central publisher" }; step["with"]["ref"] = "main"; File.write(path, YAML.dump(data) + "# immutable central action revision\n")'
mutate_workflow wrong_central_repository \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); step = data["jobs"]["publish"]["steps"].find { |item| item["name"] == "Checkout central publisher" }; step["with"]["repository"] = "example/docs"; File.write(path, YAML.dump(data) + "# jacobcxdev/jacobcxdev.github.io\n")'
mutate_workflow missing_central_token \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); step = data["jobs"]["publish"]["steps"].find { |item| item["name"] == "Publish through central index" }; step["with"].delete("token"); File.write(path, YAML.dump(data) + "# INDEX_REPO_TOKEN\n")'
mutate_workflow publish_continue_on_error \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); step = data["jobs"]["publish"]["steps"].find { |item| item["name"] == "Publish through central index" }; step["continue-on-error"] = true; File.write(path, YAML.dump(data))'
mutate_workflow action_pin_bypass \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); data["jobs"]["build"]["steps"].find { |item| item["uses"]&.start_with?("actions/checkout@") }["uses"] = "actions/checkout@v7"; File.write(path, YAML.dump(data) + "# actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1\n")'
mutate_workflow validation_bypass \
    'path = ARGV.fetch(0); data = YAML.safe_load_file(path, aliases: false); data["jobs"]["build"]["steps"].reject! { |item| item["name"] == "Validate rendered appcasts" }; File.write(path, YAML.dump(data) + "# xmllint --noout AppCast/_site/appcast.xml AppCast/_site/appcast-prereleases.xml\n")'
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
    "$repo_root/Scripts/extract_sparkle_signature.rb" \
    "$repo_root/Scripts/inspect_app_archive.rb" \
    "$repo_root/Scripts/validate_appcast_history.rb" \
    "$repo_root/Scripts/validate_appcast_release.sh" \
    "$repo_root/Scripts/validate_rendered_appcast.rb" \
    "$repo_root/Scripts/verify_sparkle_signature.swift" \
    "$identity_fixture/Scripts/"
cp "$repo_root/Xcodes/Frontend/Preferences/UpdatesPreferencePane.swift" "$identity_fixture/Xcodes/Frontend/Preferences/"
cp "$repo_root/Xcodes/Resources/Info.plist" "$identity_fixture/Xcodes/Resources/"

perl -0pi -e \
    's~ruby "\$repo_root/Scripts/inspect_app_archive\.rb" "\$release_dir/Xcodes\.zip" >/dev/null~true # archive inspector bypassed~' \
    "$identity_fixture/Scripts/validate_appcast_release.sh"
expect_failure archive_inspector_bypass "$identity_fixture/Scripts/check_appcast_identity.sh" "$identity_fixture"
cp "$repo_root/Scripts/validate_appcast_release.sh" "$identity_fixture/Scripts/validate_appcast_release.sh"

plutil -replace SUPublicEDKey -string "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" \
    "$identity_fixture/Xcodes/Resources/Info.plist"
perl -0pi -e \
    's#</plist>#<!-- CbToeJaT+HbP9oQAtNtKtBABQhYYisM4Y/fI8q2gcF8= -->\n</plist>#' \
    "$identity_fixture/Xcodes/Resources/Info.plist"
expect_failure public_key "$identity_fixture/Scripts/check_appcast_identity.sh" "$identity_fixture"
cp "$repo_root/Xcodes/Resources/Info.plist" "$identity_fixture/Xcodes/Resources/Info.plist"

perl -0pi -e \
    's#static let prereleaseAppcast = "https://docs\.jacobcx\.dev/repo/1330187036/updates/appcast-prereleases\.xml"#static let prereleaseAppcast = "https://example.invalid/appcast-prereleases.xml"\n    // static let prereleaseAppcast = "https://docs.jacobcx.dev/repo/1330187036/updates/appcast-prereleases.xml"#' \
    "$identity_fixture/Xcodes/Frontend/Preferences/UpdatesPreferencePane.swift"
expect_failure prerelease_feed "$identity_fixture/Scripts/check_appcast_identity.sh" "$identity_fixture"

template_fixture="$test_root/template"
cp -R "$repo_root/AppCast" "$template_fixture"
perl -0pi -e 's/site\.data\.validated_releases/site.github.releases/' \
    "$template_fixture/_includes/appcast.inc"
expect_failure raw_release_template env APPCAST_SOURCE="$template_fixture" \
    bundle exec --gemfile "$repo_root/AppCast/Gemfile" ruby "$repo_root/AppCast/test_appcast.rb"

filter_fixture="$test_root/filter"
cp -R "$repo_root/AppCast" "$filter_fixture"
perl -0pi -e \
    's/signatures\.fetch\(release_tag\) do.*?end/signatures.values.first/ms' \
    "$filter_fixture/_plugins/signature_filter.rb"
expect_failure permissive_signature_filter env APPCAST_SOURCE="$filter_fixture" \
    bundle exec --gemfile "$repo_root/AppCast/Gemfile" ruby "$repo_root/AppCast/test_appcast.rb"

echo "Appcast contract mutation tests passed"
