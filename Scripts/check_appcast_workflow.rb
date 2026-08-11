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
        "expected_release_tag" => {
          "description" => "Published release tag matching vX.Y.ZbN",
          "required" => true,
          "type" => "string",
        },
      },
    },
    "workflow_dispatch" => {
      "inputs" => {
        "expected_release_tag" => {
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
    "group" => "appcast-${{ inputs.expected_release_tag || github.event.release.tag_name }}",
    "cancel-in-progress" => false,
  },
  "Appcast concurrency contract changed"
)

jobs = workflow.fetch("jobs", {})
check.call(jobs.keys.sort == %w[build deploy], "Appcast workflow must contain only build and deploy jobs")

build = jobs.fetch("build", {})
deploy = jobs.fetch("deploy", {})
repository_guard = "github.repository == 'jacobcxdev/XcodesApp'"

check.call(build["if"] == repository_guard, "Build job must be restricted to fork repository")
check.call(build["permissions"] == { "contents" => "read" }, "Build job permissions must be contents: read")
check.call(build["runs-on"] == "ubuntu-latest", "Build job runner changed")
check.call(
  build["env"] == {
    "BUNDLER_VERSION" => bundler_version,
    "BUNDLE_FROZEN" => "true",
    "BUNDLE_PATH" => "vendor/bundle",
  },
  "Build environment must contain only pinned Bundler settings"
)

check.call(deploy["if"] == repository_guard, "Deploy job must be restricted to fork repository")
check.call(deploy["needs"] == "build", "Deploy job must require verified build artifact")
check.call(deploy["permissions"] == { "contents" => "write" }, "Deploy job alone must have contents: write")
check.call(deploy["runs-on"] == "ubuntu-latest", "Deploy job runner changed")

build_steps = build.fetch("steps", [])
deploy_steps = deploy.fetch("steps", [])

checkout_sha = "11bd71901bbe5b1630ceea73d27597364c9af683"
ruby_sha = "7bae1d00b5db9166f4f0fc47985a3a5702cb58f0"
upload_sha = "ea165f8d65b6e75b540449e92b4886f43607fa02"
download_sha = "d3f86a106a0bac45b974a628896c90dbdf5c8093"
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
    "name" => "Checkout",
    "uses" => "actions/checkout@#{checkout_sha}",
    "with" => { "persist-credentials" => false },
  },
  {
    "name" => "Validate expected published release",
    "env" => {
      "GH_TOKEN" => "${{ github.token }}",
      "EXPECTED_RELEASE_TAG" => "${{ inputs.expected_release_tag || github.event.release.tag_name }}",
    },
    "run" => <<~'SHELL'.strip,
      set -euo pipefail
      [[ "$EXPECTED_RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+b(0|[1-9][0-9]*)$ ]] || { echo "Expected release tag must match vX.Y.ZbN exactly" >&2; exit 1; }
      release_json="$(gh api "repos/$GITHUB_REPOSITORY/releases/tags/$EXPECTED_RELEASE_TAG")"
      readonly release_json
      jq -e --arg tag "$EXPECTED_RELEASE_TAG" '
        (.tag_name == $tag) and
        (.draft == false) and
        (.prerelease == false) and
        ((.assets | type) == "array") and
        (([.assets[].name] | sort) == ([
          "Xcodes.zip",
          "Xcodes.zip.sha256",
          "release-manifest.txt",
          "sparkle-signature.txt"
        ] | sort)) and
        (all(.assets[]; ((.size | type) == "number") and (.size > 0))) and
        ([
          .assets[]
          | select(
              ((.name | type) == "string") and
              (.name | ascii_downcase | endswith(".zip"))
            )
          | .name
        ] == ["Xcodes.zip"])
      ' <<< "$release_json" >/dev/null
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
    "env" => { "JEKYLL_GITHUB_TOKEN" => "${{ github.token }}" },
    "run" => 'bundle "_${BUNDLER_VERSION}_" exec jekyll build',
  },
  {
    "name" => "Validate rendered appcasts",
    "run" => "xmllint --noout AppCast/_site/appcast.xml AppCast/_site/appcast_pre.xml",
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
check.call(checkout.fetch("with", {}) == { "persist-credentials" => false }, "Checkout credentials must not persist")

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
check.call(
  jekyll_build["env"] == { "JEKYLL_GITHUB_TOKEN" => "${{ github.token }}" },
  "Jekyll metadata step must receive only job-scoped GitHub token"
)

xml_validation = build_steps.find { |step| step["name"] == "Validate rendered appcasts" } || {}
expected_xml_validation = "xmllint --noout AppCast/_site/appcast.xml AppCast/_site/appcast_pre.xml"
check.call(xml_validation["run"] == expected_xml_validation, "Both rendered appcasts must pass xmllint before upload")

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
