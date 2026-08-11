#!/usr/bin/env ruby

require "yaml"

workflow_path = ARGV.fetch(0)
lockfile_path = ARGV.fetch(1)

workflow = YAML.safe_load_file(workflow_path, aliases: false)
errors = []

check = lambda do |condition, message|
  errors << message unless condition
end

bundler_version = File.read(lockfile_path).match(/\nBUNDLED WITH\n\s+([^\s]+)\s*\z/)&.captures&.first
check.call(!bundler_version.nil?, "Unable to read pinned Bundler version")
check.call(
  workflow.keys.sort == %w[concurrency jobs name on permissions],
  "Unexpected top-level appcast workflow capability"
)

check.call(
  workflow["on"] == {
    "workflow_call" => {
      "inputs" => {
        "tag" => {
          "description" => "Published release tag matching vX.Y.ZbN",
          "required" => true,
          "type" => "string",
        },
      },
    },
    "workflow_dispatch" => {
      "inputs" => {
        "tag" => {
          "description" => "Published release tag matching vX.Y.ZbN",
          "required" => true,
          "type" => "string",
        },
      },
    },
    "release" => { "types" => ["published"] },
  },
  "Appcast workflow trigger and reusable input contract changed"
)
check.call(workflow["permissions"] == { "contents" => "read" }, "Top-level permissions must be contents: read")
check.call(
  workflow["concurrency"] == {
    "group" => "appcast-${{ github.repository }}",
    "cancel-in-progress" => false,
  },
  "Appcast concurrency contract changed"
)

jobs = workflow.fetch("jobs", {})
check.call(jobs.keys.sort == %w[build deploy], "Appcast workflow must contain only build and deploy jobs")

build = jobs.fetch("build", {})
deploy = jobs.fetch("deploy", {})
expected_release_tag = "${{ inputs.tag || github.event.release.tag_name }}"
repository_guard = "github.repository == 'jacobcxdev/XcodesApp'"
build_guard = "#{repository_guard} && github.ref == format('refs/tags/{0}', inputs.tag || github.event.release.tag_name)"

check.call(build["if"] == build_guard, "Build job must be restricted to fork repository and exact tag ref")
check.call(build["permissions"] == { "contents" => "read" }, "Build job permissions must be contents: read")
check.call(build["runs-on"] == "macos-26", "Build job runner changed")
check.call(build["timeout-minutes"] == 60, "Build timeout must remain bounded")
check.call(build.keys.sort == %w[env if permissions runs-on steps timeout-minutes], "Unexpected build job capability")
check.call(
  build["env"] == {
    "BUNDLER_VERSION" => bundler_version,
    "BUNDLE_FROZEN" => "true",
    "BUNDLE_PATH" => "vendor/bundle",
    "EXPECTED_RELEASE_TAG" => expected_release_tag,
  },
  "Build environment must contain only pinned Bundler settings"
)

check.call(deploy["if"] == repository_guard, "Deploy job must be restricted to fork repository")
check.call(deploy["needs"] == "build", "Deploy job must require verified build artifact")
check.call(deploy["permissions"] == { "contents" => "write" }, "Deploy job alone must have contents: write")
check.call(deploy["runs-on"] == "ubuntu-latest", "Deploy job runner changed")
check.call(deploy["timeout-minutes"] == 10, "Deploy timeout must remain bounded")
check.call(deploy.keys.sort == %w[if needs permissions runs-on steps timeout-minutes], "Unexpected deploy job capability")

build_steps = build.fetch("steps", [])
deploy_steps = deploy.fetch("steps", [])

checkout_sha = "3d3c42e5aac5ba805825da76410c181273ba90b1"
ruby_sha = "95ef2b042f9d7a56d8268cba8559e2842e2ad01b"
upload_sha = "043fb46d1a93c77aae656e7c1c64a875d1fc6a0a"
download_sha = "3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c"
deploy_sha = "fa24774553152dd7873cd16ebd8d959b010c5445"

expected_build_uses = [
  "actions/checkout@#{checkout_sha}",
  "ruby/setup-ruby@#{ruby_sha}",
  "actions/upload-artifact@#{upload_sha}",
]
expected_deploy_uses = [
  "actions/download-artifact@#{download_sha}",
  "JamesIves/github-pages-deploy-action@#{deploy_sha}",
]

expected_build_steps = [
  {
    "name" => "Checkout expected release tag",
    "uses" => "actions/checkout@#{checkout_sha}",
    "with" => {
      "ref" => expected_release_tag,
      "fetch-depth" => 0,
      "persist-credentials" => false,
    },
  },
  {
    "name" => "Verify immutable appcast source",
    "run" => <<~'SHELL'.strip,
      set -euo pipefail
      [[ "$EXPECTED_RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+b(0|[1-9][0-9]*)$ ]] || { echo "Expected release tag must match vX.Y.ZbN exactly" >&2; exit 1; }
      [[ "$GITHUB_REF" == "refs/tags/$EXPECTED_RELEASE_TAG" ]] || { echo "Workflow must run from refs/tags/$EXPECTED_RELEASE_TAG" >&2; exit 1; }
      git fetch --force --no-tags origin \
        "+refs/heads/main:refs/remotes/origin/main" \
        "+refs/tags/$EXPECTED_RELEASE_TAG:refs/tags/$EXPECTED_RELEASE_TAG"
      source_sha="$(git rev-parse 'HEAD^{commit}')"
      readonly source_sha
      [[ "$source_sha" == "$(git rev-parse "$EXPECTED_RELEASE_TAG^{commit}")" ]] || { echo "Appcast tag does not point at checked-out commit" >&2; exit 1; }
      git merge-base --is-ancestor "$source_sha" origin/main || { echo "Appcast source is not on origin/main" >&2; exit 1; }
    SHELL
  },
  {
    "name" => "Verify fork appcast identity",
    "run" => "bash Scripts/check_appcast_identity.sh",
  },
  {
    "name" => "Validate complete published release history",
    "env" => { "GH_TOKEN" => "${{ github.token }}" },
    "run" => <<~'SHELL'.strip,
      set -euo pipefail
      umask 077
      release_root="$(mktemp -d "$RUNNER_TEMP/appcast-releases.XXXXXX")"
      readonly release_root
      readonly validated_releases="$GITHUB_WORKSPACE/AppCast/_data/validated_releases.json"
      readonly validated_signatures="$RUNNER_TEMP/validated-release-signatures.json"
      readonly verifier="$RUNNER_TEMP/verify-sparkle-signature"
      install -d -m 700 "$GITHUB_WORKSPACE/AppCast/_data"
      xcrun swiftc -parse-as-library Scripts/verify_sparkle_signature.swift -o "$verifier"
      ruby Scripts/validate_appcast_history.rb \
        "$EXPECTED_RELEASE_TAG" \
        "$release_root" \
        "$validated_releases" \
        "$validated_signatures" \
        "$verifier" \
        "$GITHUB_WORKSPACE/Xcodes/Resources/Info.plist" \
        "$GITHUB_WORKSPACE"
      printf 'VALIDATED_RELEASES_FILE=%s\nVALIDATED_RELEASE_SIGNATURES_FILE=%s\n' \
        "$validated_releases" "$validated_signatures" >> "$GITHUB_ENV"
    SHELL
  },
  {
    "name" => "Setup Ruby",
    "uses" => "ruby/setup-ruby@#{ruby_sha}",
    "with" => { "ruby-version" => "3.3" },
  },
  {
    "name" => "Install pinned Bundler",
    "run" => 'gem install bundler --version "$BUNDLER_VERSION" --no-document',
  },
  {
    "name" => "Install dependencies",
    "working-directory" => "AppCast",
    "run" => 'bundle "_${BUNDLER_VERSION}_" install --jobs 4 --retry 3',
  },
  {
    "name" => "Test appcast generation",
    "working-directory" => "AppCast",
    "run" => 'bundle "_${BUNDLER_VERSION}_" exec ruby test_appcast.rb',
  },
  {
    "name" => "Build appcasts",
    "working-directory" => "AppCast",
    "run" => 'bundle "_${BUNDLER_VERSION}_" exec jekyll build',
  },
  {
    "name" => "Validate rendered appcasts",
    "run" => <<~'SHELL'.strip,
      set -euo pipefail
      xmllint --noout AppCast/_site/appcast.xml AppCast/_site/appcast_pre.xml
      ruby Scripts/validate_rendered_appcast.rb \
        AppCast/_site/appcast.xml \
        AppCast/_site/appcast_pre.xml \
        "$VALIDATED_RELEASES_FILE" \
        "$VALIDATED_RELEASE_SIGNATURES_FILE"
    SHELL
  },
  {
    "name" => "Upload verified appcasts",
    "uses" => "actions/upload-artifact@#{upload_sha}",
    "with" => {
      "name" => "appcast-site",
      "path" => "AppCast/_site",
      "if-no-files-found" => "error",
      "retention-days" => 1,
    },
  },
]
expected_deploy_steps = [
  {
    "name" => "Download verified appcasts",
    "uses" => "actions/download-artifact@#{download_sha}",
    "with" => { "name" => "appcast-site", "path" => "AppCast/_site" },
  },
  {
    "name" => "Publish GitHub Pages branch",
    "uses" => "JamesIves/github-pages-deploy-action@#{deploy_sha}",
    "with" => {
      "token" => "${{ github.token }}",
      "branch" => "gh-pages",
      "folder" => "AppCast/_site",
      "clean" => true,
      "single-commit" => true,
    },
  },
]

normalise_steps = lambda do |steps|
  steps.map do |step|
    step = step.dup
    step["run"] = step["run"].strip if step["run"]
    step
  end
end
check.call(normalise_steps.call(build_steps) == expected_build_steps, "Build steps must exactly match audited controls")
check.call(deploy_steps == expected_deploy_steps, "Deploy steps must exactly match audited controls")

build_uses = build_steps.filter_map { |step| step["uses"] }
deploy_uses = deploy_steps.filter_map { |step| step["uses"] }
check.call(build_uses == expected_build_uses, "Build actions must use audited commit pins")
check.call(deploy_uses == expected_deploy_uses, "Deploy actions must use audited commit pins")
check.call(
  (build_uses + deploy_uses).all? { |uses| uses.match?(/@[0-9a-f]{40}\z/) },
  "Every appcast action must be pinned to a full commit SHA"
)

checkout = build_steps.find { |step| step["uses"]&.start_with?("actions/checkout@") } || {}
check.call(
  checkout.fetch("with", {}) == {
    "ref" => expected_release_tag,
    "fetch-depth" => 0,
    "persist-credentials" => false,
  },
  "Checkout must resolve the exact expected tag without persisted credentials"
)

setup_ruby = build_steps.find { |step| step["uses"]&.start_with?("ruby/setup-ruby@") } || {}
check.call(setup_ruby.fetch("with", {}) == { "ruby-version" => "3.3" }, "Ruby runtime pin changed")

install_bundler = build_steps.find { |step| step["name"] == "Install pinned Bundler" } || {}
check.call(
  install_bundler["run"] == 'gem install bundler --version "$BUNDLER_VERSION" --no-document',
  "Bundler installation must use exact lockfile version"
)
check.call(install_bundler["env"].nil?, "Bundler installation must not receive step credentials")

install_dependencies = build_steps.find { |step| step["name"] == "Install dependencies" } || {}
check.call(install_dependencies["working-directory"] == "AppCast", "Dependencies must install from AppCast")
check.call(
  install_dependencies["run"] == 'bundle "_${BUNDLER_VERSION}_" install --jobs 4 --retry 3',
  "Dependency installation must use pinned Bundler"
)
dependency_material = [install_dependencies["run"], install_dependencies["env"]].join("\n")
check.call(!dependency_material.match?(/GITHUB_TOKEN|github\.token|secrets\./i), "Dependency installation must not receive a GitHub token")

fixture_test = build_steps.find { |step| step["name"] == "Test appcast generation" } || {}
check.call(fixture_test["working-directory"] == "AppCast", "Appcast fixtures must run from AppCast")
check.call(
  fixture_test["run"] == 'bundle "_${BUNDLER_VERSION}_" exec ruby test_appcast.rb',
  "Appcast fixture validation is missing"
)

jekyll_build = build_steps.find { |step| step["name"] == "Build appcasts" } || {}
check.call(jekyll_build["working-directory"] == "AppCast", "Jekyll must build from AppCast")
check.call(
  jekyll_build["run"] == 'bundle "_${BUNDLER_VERSION}_" exec jekyll build',
  "Jekyll build command changed"
)
check.call(jekyll_build["env"].nil?, "Jekyll must not receive raw GitHub release authority")

xml_validation = build_steps.find { |step| step["name"] == "Validate rendered appcasts" } || {}
expected_xml_validation = <<~'SHELL'.strip
  set -euo pipefail
  xmllint --noout AppCast/_site/appcast.xml AppCast/_site/appcast_pre.xml
  ruby Scripts/validate_rendered_appcast.rb \
    AppCast/_site/appcast.xml \
    AppCast/_site/appcast_pre.xml \
    "$VALIDATED_RELEASES_FILE" \
    "$VALIDATED_RELEASE_SIGNATURES_FILE"
SHELL
check.call(xml_validation["run"]&.strip == expected_xml_validation, "Both rendered appcasts must pass xmllint before upload")

upload = build_steps.find { |step| step["uses"]&.start_with?("actions/upload-artifact@") } || {}
check.call(
  upload["with"] == {
    "name" => "appcast-site",
    "path" => "AppCast/_site",
    "if-no-files-found" => "error",
    "retention-days" => 1,
  },
  "Verified appcast artifact contract changed"
)

download = deploy_steps.find { |step| step["uses"]&.start_with?("actions/download-artifact@") } || {}
check.call(download["with"] == { "name" => "appcast-site", "path" => "AppCast/_site" }, "Deploy must download verified appcast artifact")

publish = deploy_steps.find { |step| step["uses"]&.start_with?("JamesIves/github-pages-deploy-action@") } || {}
check.call(
  publish["with"] == {
    "token" => "${{ github.token }}",
    "branch" => "gh-pages",
    "folder" => "AppCast/_site",
    "clean" => true,
    "single-commit" => true,
  },
  "GitHub Pages deployment contract changed"
)

unless errors.empty?
  warn errors.map { |error| "- #{error}" }.join("\n")
  exit 1
end

puts "Appcast workflow contract passed"
