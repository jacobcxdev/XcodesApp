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
      "secrets" => {
        "INDEX_REPO_TOKEN" => {
          "description" => "Token scoped to write jacobcxdev/jacobcxdev.github.io",
          "required" => true,
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
check.call(jobs.keys.sort == %w[build publish], "Appcast workflow must contain only build and publish jobs")

build = jobs.fetch("build", {})
publish_job = jobs.fetch("publish", {})
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

check.call(publish_job["if"] == repository_guard, "Publish job must be restricted to fork repository")
check.call(publish_job["needs"] == "build", "Publish job must require verified build artifact")
check.call(publish_job["permissions"] == { "contents" => "read" }, "Publish job permissions must be contents: read")
check.call(publish_job["runs-on"] == "ubuntu-latest", "Publish job runner changed")
check.call(publish_job["timeout-minutes"] == 10, "Publish timeout must remain bounded")
check.call(publish_job.keys.sort == %w[if needs permissions runs-on steps timeout-minutes], "Unexpected publish job capability")

build_steps = build.fetch("steps", [])
publish_steps = publish_job.fetch("steps", [])

checkout_sha = "3d3c42e5aac5ba805825da76410c181273ba90b1"
ruby_sha = "95ef2b042f9d7a56d8268cba8559e2842e2ad01b"
upload_sha = "043fb46d1a93c77aae656e7c1c64a875d1fc6a0a"
download_sha = "3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c"
setup_node_sha = "249970729cb0ef3589644e2896645e5dc5ba9c38"
central_action_sha = "bc53a309ec69ce6e39dc209535ef24732683902e"

expected_build_uses = [
  "actions/checkout@#{checkout_sha}",
  "ruby/setup-ruby@#{ruby_sha}",
  "actions/upload-artifact@#{upload_sha}",
]
expected_publish_uses = [
  "actions/download-artifact@#{download_sha}",
  "actions/setup-node@#{setup_node_sha}",
  "actions/checkout@#{checkout_sha}",
  "./action-checkout/actions/publish-appcast",
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
      xmllint --noout AppCast/_site/appcast.xml AppCast/_site/appcast-prereleases.xml
      ruby Scripts/validate_rendered_appcast.rb \
        AppCast/_site/appcast.xml \
        AppCast/_site/appcast-prereleases.xml \
        "$VALIDATED_RELEASES_FILE" \
        "$VALIDATED_RELEASE_SIGNATURES_FILE"
    SHELL
  },
  {
    "name" => "Upload verified appcasts",
    "uses" => "actions/upload-artifact@#{upload_sha}",
    "with" => {
      "name" => "appcast-site",
      "path" => "AppCast/_site/appcast*.xml",
      "if-no-files-found" => "error",
      "retention-days" => 1,
    },
  },
]
expected_publish_steps = [
  {
    "name" => "Download verified appcasts",
    "uses" => "actions/download-artifact@#{download_sha}",
    "with" => { "name" => "appcast-site", "path" => "AppCast/_site" },
  },
  {
    "name" => "Setup Node.js",
    "uses" => "actions/setup-node@#{setup_node_sha}",
    "with" => { "node-version" => "25" },
  },
  {
    "name" => "Checkout central publisher",
    "uses" => "actions/checkout@#{checkout_sha}",
    "with" => {
      "repository" => "jacobcxdev/jacobcxdev.github.io",
      "ref" => central_action_sha,
      "path" => "action-checkout",
      "persist-credentials" => false,
      "token" => "${{ secrets.INDEX_REPO_TOKEN }}",
    },
  },
  {
    "name" => "Publish through central index",
    "uses" => "./action-checkout/actions/publish-appcast",
    "with" => {
      "token" => "${{ secrets.INDEX_REPO_TOKEN }}",
      "source-dir" => "AppCast/_site",
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
check.call(normalise_steps.call(publish_steps) == expected_publish_steps, "Publish steps must exactly match audited controls")

build_uses = build_steps.filter_map { |step| step["uses"] }
publish_uses = publish_steps.filter_map { |step| step["uses"] }
check.call(build_uses == expected_build_uses, "Build actions must use audited commit pins")
check.call(publish_uses == expected_publish_uses, "Publish actions must use audited pins and local central action")
check.call(
  (build_uses + publish_uses).all? { |uses| uses == "./action-checkout/actions/publish-appcast" || uses.match?(/@[0-9a-f]{40}\z/) },
  "Every external appcast action must be pinned to a full commit SHA"
)
check.call(!YAML.dump(build).match?(/INDEX_REPO_TOKEN|secrets\./), "Build job must not receive central publication credentials")
check.call(!YAML.dump(workflow).match?(/gh-pages|github-pages-deploy-action|contents:\s*write/), "XcodesApp must not publish GitHub Pages")

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
  xmllint --noout AppCast/_site/appcast.xml AppCast/_site/appcast-prereleases.xml
  ruby Scripts/validate_rendered_appcast.rb \
    AppCast/_site/appcast.xml \
    AppCast/_site/appcast-prereleases.xml \
    "$VALIDATED_RELEASES_FILE" \
    "$VALIDATED_RELEASE_SIGNATURES_FILE"
SHELL
check.call(xml_validation["run"]&.strip == expected_xml_validation, "Both rendered appcasts must pass xmllint before upload")

upload = build_steps.find { |step| step["uses"]&.start_with?("actions/upload-artifact@") } || {}
check.call(
  upload["with"] == {
    "name" => "appcast-site",
    "path" => "AppCast/_site/appcast*.xml",
    "if-no-files-found" => "error",
    "retention-days" => 1,
  },
  "Verified appcast artifact contract changed"
)

download = publish_steps.find { |step| step["uses"]&.start_with?("actions/download-artifact@") } || {}
check.call(download["with"] == { "name" => "appcast-site", "path" => "AppCast/_site" }, "Publish must download verified appcast artifact")

central_checkout = publish_steps.find { |step| step["name"] == "Checkout central publisher" } || {}
check.call(
  central_checkout["with"] == {
    "repository" => "jacobcxdev/jacobcxdev.github.io",
    "ref" => central_action_sha,
    "path" => "action-checkout",
    "persist-credentials" => false,
    "token" => "${{ secrets.INDEX_REPO_TOKEN }}",
  },
  "Central publisher checkout must use exact immutable revision"
)

central_publish = publish_steps.find { |step| step["uses"] == "./action-checkout/actions/publish-appcast" } || {}
check.call(
  central_publish["with"] == {
    "token" => "${{ secrets.INDEX_REPO_TOKEN }}",
    "source-dir" => "AppCast/_site",
  },
  "Central appcast publication contract changed"
)

unless errors.empty?
  warn errors.map { |error| "- #{error}" }.join("\n")
  exit 1
end

puts "Appcast workflow contract passed"
