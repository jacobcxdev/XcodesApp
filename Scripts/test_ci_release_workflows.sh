#!/bin/bash

set -euo pipefail

readonly repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly checker="$repo_root/Scripts/check_ci_release_workflows.rb"
readonly test_root="$(mktemp -d "${TMPDIR:-/tmp}/xcodes-workflow-tests.XXXXXX")"

cleanup() {
    rm -rf -- "$test_root"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

make_fixture() {
    local name="$1"
    local fixture="$test_root/$name"

    mkdir -p "$fixture/.github/workflows" "$fixture/Scripts" "$fixture/docs"
    cp "$repo_root/.github/workflows/"*.yml "$fixture/.github/workflows/"
    cp "$checker" "$fixture/Scripts/check_ci_release_workflows.rb"
    cp "$repo_root/docs/RELEASING.md" "$fixture/docs/RELEASING.md"
    printf '%s\n' "$fixture"
}

mutate_and_reject() {
    local name="$1"
    local script="$2"
    local fixture

    fixture="$(make_fixture "$name")"
    ruby -ryaml -e "$script" "$fixture"
    if ruby "$fixture/Scripts/check_ci_release_workflows.rb" >/dev/null 2>&1; then
        fail "Workflow checker accepted mutation: $name"
    fi
}

ruby "$checker"

mutate_and_reject missing_ci_ruby_setup \
    'path = File.join(ARGV.fetch(0), ".github/workflows/ci.yml"); data = YAML.safe_load_file(path, aliases: false); data["jobs"]["verify"]["steps"].reject! { |step| step["name"] == "Setup Ruby and appcast dependencies" }; File.write(path, YAML.dump(data) + "# pinned Ruby and Bundler setup\n")'
mutate_and_reject wrong_ci_ruby_version \
    'path = File.join(ARGV.fetch(0), ".github/workflows/ci.yml"); data = YAML.safe_load_file(path, aliases: false); step = data["jobs"]["verify"]["steps"].find { |item| item["name"] == "Setup Ruby and appcast dependencies" }; step && step["with"]["ruby-version"] = "ruby-head"; File.write(path, YAML.dump(data) + "# ruby-version: 3.3\n")'
mutate_and_reject unpinned_ci_ruby_action \
    'path = File.join(ARGV.fetch(0), ".github/workflows/ci.yml"); data = YAML.safe_load_file(path, aliases: false); step = data["jobs"]["verify"]["steps"].find { |item| item["name"] == "Setup Ruby and appcast dependencies" }; step && step["uses"] = "ruby/setup-ruby@v1"; File.write(path, YAML.dump(data) + "# full action SHA\n")'
mutate_and_reject wrong_ci_bundler \
    'path = File.join(ARGV.fetch(0), ".github/workflows/ci.yml"); data = YAML.safe_load_file(path, aliases: false); step = data["jobs"]["verify"]["steps"].find { |item| item["name"] == "Setup Ruby and appcast dependencies" }; step && step["with"]["bundler"] = "latest"; File.write(path, YAML.dump(data) + "# bundler: 4.0.16\n")'
mutate_and_reject comment_permission_bypass \
    'path = File.join(ARGV.fetch(0), ".github/workflows/release.yml"); data = YAML.safe_load_file(path, aliases: false); data["jobs"]["package"]["permissions"]["contents"] = "write"; File.write(path, YAML.dump(data) + "# contents: read\n")'
mutate_and_reject widened_trigger \
    'path = File.join(ARGV.fetch(0), ".github/workflows/release.yml"); data = YAML.safe_load_file(path, aliases: false); data["on"]["push"]["branches"] = ["main"]; File.write(path, YAML.dump(data) + "# tags: [exact version pattern]\n")'
mutate_and_reject unpinned_action \
    'path = File.join(ARGV.fetch(0), ".github/workflows/release-drafter.yml"); data = YAML.safe_load_file(path, aliases: false); data["jobs"]["update_release_draft"]["steps"][0]["uses"] = "release-drafter/release-drafter@v7"; File.write(path, YAML.dump(data) + "# release-drafter/release-drafter@34d80673e067bdc0c24568d3af899c216adcfaa9\n")'
mutate_and_reject unpinned_reusable_workflow \
    'path = File.join(ARGV.fetch(0), ".github/workflows/bypass.yaml"); File.write(path, YAML.dump({ "name" => "bypass", "on" => { "workflow_dispatch" => nil }, "jobs" => { "bypass" => { "uses" => "owner/repository/.github/workflows/example.yml@main" } } }))'
mutate_and_reject missing_repository_guard \
    'path = File.join(ARGV.fetch(0), ".github/workflows/release.yml"); data = YAML.safe_load_file(path, aliases: false); data["jobs"]["publish"]["if"] = "always()"; File.write(path, YAML.dump(data) + "# github.repository == jacobcxdev/XcodesApp\n")'
mutate_and_reject missing_environment \
    'path = File.join(ARGV.fetch(0), ".github/workflows/release.yml"); data = YAML.safe_load_file(path, aliases: false); data["jobs"]["package"].delete("environment"); File.write(path, YAML.dump(data) + "# environment: release\n")'
mutate_and_reject widened_concurrency \
    'path = File.join(ARGV.fetch(0), ".github/workflows/release.yml"); data = YAML.safe_load_file(path, aliases: false); data["concurrency"]["group"] = "release-global"; File.write(path, YAML.dump(data) + "# release-${{ inputs.release_tag || github.ref_name }}\n")'
mutate_and_reject missing_cleanup \
    'path = File.join(ARGV.fetch(0), ".github/workflows/release.yml"); data = YAML.safe_load_file(path, aliases: false); data["jobs"]["package"]["steps"].reject! { |step| step["name"] == "Remove release credentials" }; File.write(path, YAML.dump(data) + "# if: always()\n")'
mutate_and_reject exposed_secret \
    'path = File.join(ARGV.fetch(0), ".github/workflows/release.yml"); data = YAML.safe_load_file(path, aliases: false); step = data["jobs"]["package"]["steps"].find { |item| item["name"] == "Import protected release credentials" }; step["run"] += "\necho $CERTIFICATE_P12_BASE64"; File.write(path, YAML.dump(data) + "# printf secret safely\n")'
mutate_and_reject wrong_artifact_path \
    'path = File.join(ARGV.fetch(0), ".github/workflows/release.yml"); data = YAML.safe_load_file(path, aliases: false); step = data["jobs"]["package"]["steps"].find { |item| item["name"] == "Upload verified release artifact" }; step["with"]["path"] = "Product"; File.write(path, YAML.dump(data) + "# Product/${{ steps.release.outputs.tag }}\n")'
mutate_and_reject missing_verification \
    'path = File.join(ARGV.fetch(0), ".github/workflows/release.yml"); data = YAML.safe_load_file(path, aliases: false); data["jobs"]["publish"]["steps"].reject! { |step| step["name"] == "Revalidate downloaded artifact" }; File.write(path, YAML.dump(data) + "# validate_release_artifacts.sh\n")'
mutate_and_reject publish_secret_access \
    'path = File.join(ARGV.fetch(0), ".github/workflows/release.yml"); data = YAML.safe_load_file(path, aliases: false); data["jobs"]["publish"]["env"] = { "KEY" => "${{ secrets.SPARKLE_PRIVATE_KEY }}" }; File.write(path, YAML.dump(data) + "# no secrets here\n")'
mutate_and_reject mutable_checkout \
    'path = File.join(ARGV.fetch(0), ".github/workflows/release.yml"); data = YAML.safe_load_file(path, aliases: false); step = data["jobs"]["package"]["steps"].find { |item| item["name"] == "Checkout immutable release tag" }; step["with"]["ref"] = "main"; File.write(path, YAML.dump(data) + "# ref: exact tag\n")'
mutate_and_reject missing_appcast_call \
    'path = File.join(ARGV.fetch(0), ".github/workflows/release.yml"); data = YAML.safe_load_file(path, aliases: false); data["jobs"].delete("appcast"); File.write(path, YAML.dump(data) + "# appcast workflow call\n")'
mutate_and_reject appcast_wrong_need \
    'path = File.join(ARGV.fetch(0), ".github/workflows/release.yml"); data = YAML.safe_load_file(path, aliases: false); data["jobs"]["appcast"]["needs"] = "package"; File.write(path, YAML.dump(data) + "# needs: publish\n")'
mutate_and_reject appcast_wrong_tag \
    'path = File.join(ARGV.fetch(0), ".github/workflows/release.yml"); data = YAML.safe_load_file(path, aliases: false); data["jobs"]["appcast"]["with"]["tag"] = "latest"; File.write(path, YAML.dump(data) + "# exact release tag\n")'
mutate_and_reject appcast_wrong_permissions \
    'path = File.join(ARGV.fetch(0), ".github/workflows/release.yml"); data = YAML.safe_load_file(path, aliases: false); data["jobs"]["appcast"]["permissions"]["contents"] = "read"; File.write(path, YAML.dump(data) + "# contents: write\n")'
mutate_and_reject appcast_secret_inheritance \
    'path = File.join(ARGV.fetch(0), ".github/workflows/release.yml"); data = YAML.safe_load_file(path, aliases: false); data["jobs"]["appcast"]["secrets"] = "inherit"; File.write(path, YAML.dump(data) + "# no secrets inherited\n")'
mutate_and_reject appcast_if_false \
    'path = File.join(ARGV.fetch(0), ".github/workflows/release.yml"); data = YAML.safe_load_file(path, aliases: false); data["jobs"]["appcast"]["if"] = false; File.write(path, YAML.dump(data) + "# repository guard\n")'
mutate_and_reject appcast_continue_on_error \
    'path = File.join(ARGV.fetch(0), ".github/workflows/release.yml"); data = YAML.safe_load_file(path, aliases: false); data["jobs"]["appcast"]["continue-on-error"] = true; File.write(path, YAML.dump(data) + "# failures must propagate\n")'
mutate_and_reject mutable_appcast_indirection \
    'path = File.join(ARGV.fetch(0), ".github/workflows/release.yml"); data = YAML.safe_load_file(path, aliases: false); data["jobs"]["appcast"]["uses"] = "jacobcxdev/XcodesApp/.github/workflows/appcast.yml@main"; File.write(path, YAML.dump(data) + "# local reusable workflow\n")'
mutate_and_reject glob_shell_syntax_bypass \
    'path = File.join(ARGV.fetch(0), ".github/workflows/ci.yml"); data = YAML.safe_load_file(path, aliases: false); step = data["jobs"]["verify"]["steps"].find { |item| item["name"] == "Validate repository contracts" }; step["run"].sub!(/shopt -s nullglob.*?done/m, "bash -n Scripts/*.sh"); File.write(path, YAML.dump(data) + "# exact script loop\n")'
mutate_and_reject omitted_supported_locales \
    'path = File.join(ARGV.fetch(0), ".github/workflows/ci.yml"); data = YAML.safe_load_file(path, aliases: false); step = data["jobs"]["verify"]["steps"].find { |item| item["name"] == "Validate localisations" }; step["run"].sub!("ar,", "").sub!(",th", ""); File.write(path, YAML.dump(data) + "# ar and th supported\n")'
mutate_and_reject missing_release_ref_binding \
    'path = File.join(ARGV.fetch(0), ".github/workflows/release.yml"); data = YAML.safe_load_file(path, aliases: false); step = data["jobs"]["package"]["steps"].find { |item| item["name"] == "Verify immutable release authority" }; step && step["run"].sub!(/^.*GITHUB_REF.*\n/, ""); File.write(path, YAML.dump(data) + "# exact tag ref\n")'
mutate_and_reject missing_package_job_ref_guard \
    'path = File.join(ARGV.fetch(0), ".github/workflows/release.yml"); data = YAML.safe_load_file(path, aliases: false); data["jobs"]["package"]["if"] = "github.repository == '\''jacobcxdev/XcodesApp'\''"; File.write(path, YAML.dump(data) + "# exact tag ref job guard\n")'
mutate_and_reject missing_main_ancestry \
    'path = File.join(ARGV.fetch(0), ".github/workflows/release.yml"); data = YAML.safe_load_file(path, aliases: false); step = data["jobs"]["package"]["steps"].find { |item| item["name"] == "Verify immutable release authority" }; step && step["run"].sub!(/^.*merge-base --is-ancestor.*\n/, ""); File.write(path, YAML.dump(data) + "# origin/main ancestry\n")'
mutate_and_reject missing_package_sha_output \
    'path = File.join(ARGV.fetch(0), ".github/workflows/release.yml"); data = YAML.safe_load_file(path, aliases: false); data["jobs"]["package"]["outputs"]&.delete("package_sha"); File.write(path, YAML.dump(data) + "# immutable package SHA\n")'
mutate_and_reject publish_tag_checkout \
    'path = File.join(ARGV.fetch(0), ".github/workflows/release.yml"); data = YAML.safe_load_file(path, aliases: false); step = data["jobs"]["publish"]["steps"].find { |item| item["name"] == "Checkout packaged commit" }; step && step["with"]["ref"] = "${{ needs.package.outputs.release_tag }}"; File.write(path, YAML.dump(data) + "# exact package SHA\n")'
mutate_and_reject missing_publish_sha_verification \
    'path = File.join(ARGV.fetch(0), ".github/workflows/release.yml"); data = YAML.safe_load_file(path, aliases: false); data["jobs"]["publish"]["steps"].reject! { |step| step["name"] == "Verify packaged release authority" }; File.write(path, YAML.dump(data) + "# compare tag and package SHA\n")'
mutate_and_reject missing_publish_toctou_check \
    'path = File.join(ARGV.fetch(0), ".github/workflows/release.yml"); data = YAML.safe_load_file(path, aliases: false); step = data["jobs"]["publish"]["steps"].find { |item| item["name"] == "Publish immutable GitHub release" }; step && step["run"].sub!(/^.*Release tag moved after validation.*\n/, ""); File.write(path, YAML.dump(data) + "# immediate tag recheck\n")'
mutate_and_reject inserted_credential_reader \
    'path = File.join(ARGV.fetch(0), ".github/workflows/release.yml"); data = YAML.safe_load_file(path, aliases: false); data["jobs"]["package"]["steps"].insert(-2, { "name" => "Read credentials", "run" => "cat $RUNNER_TEMP/sparkle-private-key" }); File.write(path, YAML.dump(data) + "# exact package steps\n")'
mutate_and_reject inserted_release_publisher \
    'path = File.join(ARGV.fetch(0), ".github/workflows/release.yml"); data = YAML.safe_load_file(path, aliases: false); data["jobs"]["publish"]["steps"] << { "name" => "Publish again", "run" => "gh release create latest" }; File.write(path, YAML.dump(data) + "# exact publish steps\n")'
mutate_and_reject package_unexpected_control \
    'path = File.join(ARGV.fetch(0), ".github/workflows/release.yml"); data = YAML.safe_load_file(path, aliases: false); step = data["jobs"]["package"]["steps"].find { |item| item["name"] == "Build, sign, notarize, and package" }; step["continue-on-error"] = true; File.write(path, YAML.dump(data) + "# no suppressed package failure\n")'
mutate_and_reject publish_unexpected_control \
    'path = File.join(ARGV.fetch(0), ".github/workflows/release.yml"); data = YAML.safe_load_file(path, aliases: false); step = data["jobs"]["publish"]["steps"].find { |item| item["name"] == "Publish immutable GitHub release" }; step["if"] = false; File.write(path, YAML.dump(data) + "# no disabled publisher\n")'
mutate_and_reject missing_release_drafter_timeout \
    'path = File.join(ARGV.fetch(0), ".github/workflows/release-drafter.yml"); data = YAML.safe_load_file(path, aliases: false); data["jobs"]["update_release_draft"].delete("timeout-minutes"); File.write(path, YAML.dump(data) + "# bounded timeout\n")'
mutate_and_reject missing_appcast_dispatch_docs \
    'path = File.join(ARGV.fetch(0), "docs/RELEASING.md"); text = File.read(path).sub("gh workflow run appcast.yml --ref v4.0.4b39 -f tag=v4.0.4b39", "gh workflow run appcast.yml --ref main -f tag=latest"); File.write(path, text)'
mutate_and_reject missing_reusable_ref_docs \
    'path = File.join(ARGV.fetch(0), "docs/RELEASING.md"); text = File.read(path).sub("Reusable workflows receive the caller'\''s `github.ref`; the appcast build requires that ref to equal `refs/tags/<tag>`", "Reusable workflows are called after release publication"); File.write(path, text)'

printf 'CI and release workflow mutation contracts passed.\n'
