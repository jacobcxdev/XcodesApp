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

    mkdir -p "$fixture/.github/workflows" "$fixture/Scripts"
    cp "$repo_root/.github/workflows/"*.yml "$fixture/.github/workflows/"
    cp "$checker" "$fixture/Scripts/check_ci_release_workflows.rb"
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

printf 'CI and release workflow mutation contracts passed.\n'
