#!/usr/bin/env ruby

require "yaml"

repo_root = File.expand_path("..", __dir__)
ci_path = File.join(repo_root, ".github/workflows/ci.yml")
release_path = File.join(repo_root, ".github/workflows/release.yml")
errors = []

check = lambda do |condition, message|
  errors << message unless condition
end

load_workflow = lambda do |path|
  unless File.file?(path)
    errors << "Missing #{path.delete_prefix("#{repo_root}/")}"
    next {}
  end

  YAML.safe_load_file(path, aliases: false) || {}
rescue Psych::Exception => error
  errors << "Invalid YAML in #{path.delete_prefix("#{repo_root}/")}: #{error.message}"
  {}
end

ci = load_workflow.call(ci_path)
release = load_workflow.call(release_path)
workflows = Dir[File.join(repo_root, ".github/workflows/*.{yml,yaml}")].to_h do |path|
  [path, load_workflow.call(path)]
end

checkout_sha = "11bd71901bbe5b1630ceea73d27597364c9af683"
upload_sha = "ea165f8d65b6e75b540449e92b4886f43607fa02"
download_sha = "d3f86a106a0bac45b974a628896c90dbdf5c8093"
repository_guard = "github.repository == 'jacobcxdev/XcodesApp'"

all_uses = lambda do |workflow|
  workflow.fetch("jobs", {}).values.flat_map do |job|
    [job["uses"], *job.fetch("steps", []).filter_map { |step| step["uses"] }].compact
  end
end

workflows.each do |path, workflow|
  all_uses.call(workflow).each do |uses|
    check.call(
      uses == "./.github/workflows/appcast.yml" || uses.match?(/\A[^@]+@[0-9a-f]{40}\z/),
      "Action is not pinned to a full commit SHA in #{path.delete_prefix("#{repo_root}/")}: #{uses}"
    )
  end
end

check.call(ci.keys.map(&:to_s).sort == %w[concurrency jobs name on permissions], "CI top-level capability changed")
check.call(
  ci["on"] == {
    "workflow_dispatch" => nil,
    "push" => { "branches" => ["main", "jacobcxdev/**", "sync/upstream-*", "upstream/**"] },
    "pull_request" => nil,
  },
  "CI triggers must cover owned and contribution branches only"
)
check.call(ci["permissions"] == { "contents" => "read" }, "CI permissions must be contents: read")
check.call(
  ci["concurrency"] == {
    "group" => "ci-${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}",
    "cancel-in-progress" => true,
  },
  "CI concurrency contract changed"
)

ci_jobs = ci.fetch("jobs", {})
check.call(ci_jobs.keys == ["verify"], "CI must contain only verify job")
verify = ci_jobs.fetch("verify", {})
check.call(verify["if"] == repository_guard, "CI job must be restricted to fork repository")
check.call(verify["runs-on"] == "macos-26", "CI runner must be macos-26")
check.call(verify["permissions"] == { "contents" => "read" }, "CI job permissions must be contents: read")
check.call(verify["timeout-minutes"] == 60, "CI timeout must remain bounded")
check.call(!YAML.dump(ci).match?(/\$\{\{\s*secrets\./), "CI must not access secrets")

ci_steps = verify.fetch("steps", [])
normalise_steps = lambda do |steps|
  steps.map do |step|
    step = step.dup
    step["run"] = step["run"].strip if step["run"]
    step
  end
end
expected_ci_steps = [
  {
    "name" => "Checkout",
    "uses" => "actions/checkout@#{checkout_sha}",
    "with" => { "persist-credentials" => false },
  },
  {
    "name" => "Select Xcode 26.5",
    "run" => <<~'SHELL'.strip,
      set -euo pipefail
      readonly xcode_path=/Applications/Xcode_26.5.app
      [[ -d "$xcode_path" ]] || { echo "Xcode 26.5 is unavailable on this runner" >&2; exit 1; }
      printf 'DEVELOPER_DIR=%s/Contents/Developer\n' "$xcode_path" >> "$GITHUB_ENV"
      "$xcode_path/Contents/Developer/usr/bin/xcodebuild" -version
    SHELL
  },
  {
    "name" => "Validate repository contracts",
    "run" => <<~'SHELL'.strip,
      set -euo pipefail
      bash Scripts/check_fork_identity.sh
      bash Scripts/test_fork_identity_guard.sh
      bash Scripts/check_appcast_identity.sh
      bash Scripts/test_appcast_contracts.sh
      bash Scripts/test_release_scripts.sh
      bash Scripts/test_release_artifacts.sh
      bash Scripts/test_ci_release_workflows.sh
      ruby Scripts/check_localizations.rb
      bash Scripts/test_localization_contract.sh
      shopt -s nullglob
      scripts=(Scripts/*.sh)
      ((${#scripts[@]} > 0)) || { echo "No shell scripts found" >&2; exit 1; }
      for script in "${scripts[@]}"; do
        bash -n "$script"
      done
      plutil -lint Xcodes/Resources/Info.plist dev.jacobcx.Xcodes.Helper/Info.plist dev.jacobcx.Xcodes.Helper/launchd.plist Scripts/export_options.plist
      ruby -e 'require "yaml"; Dir[".github/workflows/*.{yml,yaml}"].sort.each { |path| YAML.safe_load_file(path, aliases: false); puts path }'
      if command -v shellcheck >/dev/null 2>&1; then shellcheck --severity=error Scripts/*.sh; fi
      if command -v actionlint >/dev/null 2>&1; then actionlint; fi
    SHELL
  },
  {
    "name" => "Validate localisations",
    "env" => { "SWIFT_POLYGLOT_COMMIT" => "e3392c0b3a4b7e17ebe9f7ce888a0f0ca654a697" },
    "run" => <<~'SHELL'.strip,
      set -euo pipefail
      readonly checkout="$RUNNER_TEMP/SwiftPolyglot"
      git clone --filter=blob:none --no-checkout https://github.com/appdecostudio/SwiftPolyglot.git "$checkout"
      git -C "$checkout" checkout --detach "$SWIFT_POLYGLOT_COMMIT"
      [[ "$(git -C "$checkout" rev-parse HEAD)" == "$SWIFT_POLYGLOT_COMMIT" ]]
      swift build --package-path "$checkout" --configuration release
      swift run --package-path "$checkout" swiftpolyglot "ca,de,el,es,fi,fr,hi,it,ja,ko,nl,pl,pt-BR,ru,tr,uk,zh-Hans,zh-Hant"
    SHELL
  },
  {
    "name" => "Run full test suite",
    "run" => <<~'SHELL'.strip,
      set -euo pipefail
      xcodebuild test -quiet -project Xcodes.xcodeproj -scheme Xcodes -configuration Test -derivedDataPath "$RUNNER_TEMP/DerivedData" CODE_SIGNING_ALLOWED=NO
    SHELL
  },
  {
    "name" => "Build unsigned Debug app",
    "run" => <<~'SHELL'.strip,
      set -euo pipefail
      xcodebuild build -quiet -project Xcodes.xcodeproj -scheme Xcodes -configuration Debug -derivedDataPath "$RUNNER_TEMP/DerivedData" CODE_SIGNING_ALLOWED=NO
    SHELL
  },
]
check.call(normalise_steps.call(ci_steps) == expected_ci_steps, "CI steps must exactly match audited controls")

check.call(release.keys.map(&:to_s).sort == %w[concurrency jobs name on permissions], "Release top-level capability changed")
check.call(
  release["on"] == {
    "push" => { "tags" => ["v[0-9]+.[0-9]+.[0-9]+b[0-9]+"] },
    "workflow_dispatch" => {
      "inputs" => {
        "release_tag" => {
          "description" => "Existing tag matching vX.Y.ZbN",
          "required" => true,
          "type" => "string",
        },
      },
    },
  },
  "Release triggers must be exact tag pushes or explicit dispatch"
)
check.call(release["permissions"] == { "contents" => "read" }, "Release top-level permissions must be contents: read")
check.call(
  release["concurrency"] == {
    "group" => "release-${{ inputs.release_tag || github.ref_name }}",
    "cancel-in-progress" => false,
  },
  "Release concurrency must serialize each tag"
)

release_jobs = release.fetch("jobs", {})
check.call(release_jobs.keys == %w[package publish appcast], "Release workflow must contain only package, publish, and appcast jobs")
package = release_jobs.fetch("package", {})
publish = release_jobs.fetch("publish", {})
appcast = release_jobs.fetch("appcast", {})

check.call(package["if"] == repository_guard, "Package job must be restricted to fork repository")
check.call(package["runs-on"] == "macos-26", "Package runner must be macos-26")
check.call(package["timeout-minutes"] == 90, "Package timeout must remain bounded")
check.call(package["environment"] == "release", "Package job must use protected release environment")
check.call(package["permissions"] == { "contents" => "read" }, "Package job must not receive write permission")
check.call(package["outputs"] == { "release_tag" => "${{ steps.release.outputs.tag }}" }, "Package tag output changed")

check.call(publish["if"] == repository_guard, "Publish job must be restricted to fork repository")
check.call(publish["needs"] == "package", "Publish must require packaged artifact")
check.call(publish["runs-on"] == "ubuntu-latest", "Publish runner changed")
check.call(publish["timeout-minutes"] == 15, "Publish timeout must remain bounded")
check.call(publish["permissions"] == { "contents" => "write" }, "Publish alone must receive contents: write")
check.call(publish["environment"].nil?, "Publish job must not inherit release environment secrets")
check.call(!YAML.dump(publish).match?(/secrets\.|DEVELOPER_ID|APP_STORE_CONNECT|SPARKLE_PRIVATE|RELEASE_KEYCHAIN/), "Publish job must not access release secrets")
check.call(publish["outputs"] == { "release_tag" => "${{ needs.package.outputs.release_tag }}" }, "Publish tag output changed")

check.call(
  appcast == {
    "if" => repository_guard,
    "needs" => "publish",
    "permissions" => { "contents" => "write" },
    "uses" => "./.github/workflows/appcast.yml",
    "with" => { "expected_release_tag" => "${{ needs.publish.outputs.release_tag }}" },
  },
  "Release must invoke local appcast workflow after publication with exact tag and no secrets"
)
check.call(!YAML.dump(appcast).match?(/secrets|continue-on-error/), "Appcast caller must not inherit secrets or suppress failures")

package_steps = package.fetch("steps", [])
publish_steps = publish.fetch("steps", [])
package_step = ->(name) { package_steps.find { |step| step["name"] == name } || {} }
publish_step = ->(name) { publish_steps.find { |step| step["name"] == name } || {} }

package_checkout = package_step.call("Checkout immutable release tag")
check.call(
  package_checkout == {
    "name" => "Checkout immutable release tag",
    "uses" => "actions/checkout@#{checkout_sha}",
    "with" => {
      "ref" => "${{ inputs.release_tag || github.ref_name }}",
      "fetch-depth" => 0,
      "persist-credentials" => false,
    },
  },
  "Package checkout must resolve immutable tag without persisted credentials"
)

resolve = package_step.call("Verify immutable release tag")
check.call(resolve["id"] == "release", "Immutable tag step must expose release output")
check.call(resolve["env"] == { "RELEASE_TAG" => "${{ inputs.release_tag || github.ref_name }}" }, "Release tag must come only from event input or ref")
check.call(
  resolve["run"]&.strip == <<~'SHELL'.strip,
    set -euo pipefail
    [[ "$RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+b(0|[1-9][0-9]*)$ ]] || { echo "Release tag must match vX.Y.ZbN exactly" >&2; exit 1; }
    [[ "$(git rev-parse HEAD)" == "$(git rev-list -n 1 "$RELEASE_TAG")" ]] || { echo "Tag does not point at checked-out commit" >&2; exit 1; }
    git tag --points-at HEAD | grep -Fxq -- "$RELEASE_TAG"
    printf 'tag=%s\n' "$RELEASE_TAG" >> "$GITHUB_OUTPUT"
  SHELL
  "Immutable tag verification changed"
)

setup = package_step.call("Import protected release credentials")
expected_secrets = {
  "CERTIFICATE_P12_BASE64" => "${{ secrets.DEVELOPER_ID_APPLICATION_P12_BASE64 }}",
  "CERTIFICATE_P12_PASSWORD" => "${{ secrets.DEVELOPER_ID_APPLICATION_P12_PASSWORD }}",
  "KEYCHAIN_PASSWORD" => "${{ secrets.RELEASE_KEYCHAIN_PASSWORD }}",
  "NOTARY_KEY_ID_VALUE" => "${{ secrets.APP_STORE_CONNECT_API_KEY_ID }}",
  "NOTARY_ISSUER_ID_VALUE" => "${{ secrets.APP_STORE_CONNECT_API_ISSUER_ID }}",
  "NOTARY_PRIVATE_KEY_VALUE" => "${{ secrets.APP_STORE_CONNECT_API_PRIVATE_KEY }}",
  "SPARKLE_PRIVATE_KEY_VALUE" => "${{ secrets.SPARKLE_PRIVATE_KEY }}",
}
check.call(setup["env"] == expected_secrets, "Protected package step must receive exactly seven release secrets")
check.call(
  setup["run"]&.strip == <<~'SHELL'.strip,
    set -euo pipefail
    umask 077
    readonly certificate_path="$RUNNER_TEMP/release-certificate.p12"
    readonly keychain_path="$RUNNER_TEMP/release.keychain-db"
    readonly notary_key_path="$RUNNER_TEMP/AuthKey_${NOTARY_KEY_ID_VALUE}.p8"
    readonly sparkle_key_path="$RUNNER_TEMP/sparkle-private-key"
    [[ -n "$CERTIFICATE_P12_BASE64" && -n "$CERTIFICATE_P12_PASSWORD" && -n "$KEYCHAIN_PASSWORD" ]]
    [[ "$NOTARY_KEY_ID_VALUE" =~ ^[A-Za-z0-9]{10,}$ ]]
    [[ "$NOTARY_ISSUER_ID_VALUE" =~ ^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$ ]]
    [[ -n "$NOTARY_PRIVATE_KEY_VALUE" && -n "$SPARKLE_PRIVATE_KEY_VALUE" ]]
    printf '%s' "$CERTIFICATE_P12_BASE64" | base64 --decode > "$certificate_path"
    printf '%s' "$NOTARY_PRIVATE_KEY_VALUE" > "$notary_key_path"
    printf '%s' "$SPARKLE_PRIVATE_KEY_VALUE" > "$sparkle_key_path"
    security create-keychain -p "$KEYCHAIN_PASSWORD" "$keychain_path"
    security set-keychain-settings -lut 7200 "$keychain_path"
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$keychain_path"
    security import "$certificate_path" -k "$keychain_path" -P "$CERTIFICATE_P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$keychain_path"
    security list-keychains -d user -s "$keychain_path"
    security default-keychain -d user -s "$keychain_path"
    printf 'NOTARY_KEY_ID=%s\nNOTARY_ISSUER_ID=%s\nNOTARY_KEY_PATH=%s\nSPARKLE_PRIVATE_KEY_FILE=%s\n' \
      "$NOTARY_KEY_ID_VALUE" "$NOTARY_ISSUER_ID_VALUE" "$notary_key_path" "$sparkle_key_path" >> "$GITHUB_ENV"
  SHELL
  "Credential import must use private temporary files and Keychain"
)

package_release = package_step.call("Build, sign, notarize, and package")
check.call(package_release["env"] == { "RELEASE_TAG" => "${{ steps.release.outputs.tag }}" }, "Package command tag changed")
check.call(package_release["run"]&.strip == "set -euo pipefail\nbash Scripts/package_release.sh \"$RELEASE_TAG\"", "Package job must invoke audited release script")

validate_package = package_step.call("Validate release artifact contract")
check.call(validate_package["env"] == { "RELEASE_TAG" => "${{ steps.release.outputs.tag }}" }, "Package validation tag changed")
check.call(validate_package["run"]&.strip == "set -euo pipefail\nbash Scripts/validate_release_artifacts.sh \"Product/$RELEASE_TAG\" \"$RELEASE_TAG\"", "Package outputs must be validated before upload")

upload = package_steps.find { |step| step["uses"]&.start_with?("actions/upload-artifact@") } || {}
check.call(
  upload == {
    "name" => "Upload verified release artifact",
    "uses" => "actions/upload-artifact@#{upload_sha}",
    "with" => {
      "name" => "Xcodes-${{ steps.release.outputs.tag }}",
      "path" => "Product/${{ steps.release.outputs.tag }}",
      "if-no-files-found" => "error",
      "retention-days" => 7,
    },
  },
  "Verified release artifact upload changed"
)

cleanup = package_step.call("Remove release credentials")
check.call(cleanup["if"] == "always()", "Credential cleanup must run always")
check.call(
  cleanup["run"]&.strip == <<~'SHELL'.strip,
    set +e
    security default-keychain -d user -s login.keychain-db
    security list-keychains -d user -s login.keychain-db
    security delete-keychain "$RUNNER_TEMP/release.keychain-db"
    rm -f -- "$RUNNER_TEMP/release-certificate.p12" "$RUNNER_TEMP"/AuthKey_*.p8 "$RUNNER_TEMP/sparkle-private-key"
  SHELL
  "Credential cleanup contract changed"
)
check.call(package_steps.last == cleanup, "Credential cleanup must be final package step")

publish_checkout = publish_step.call("Checkout immutable release tag")
check.call(
  publish_checkout == {
    "name" => "Checkout immutable release tag",
    "uses" => "actions/checkout@#{checkout_sha}",
    "with" => {
      "ref" => "${{ needs.package.outputs.release_tag }}",
      "fetch-depth" => 1,
      "persist-credentials" => false,
    },
  },
  "Publish checkout must use packaged tag"
)

download = publish_steps.find { |step| step["uses"]&.start_with?("actions/download-artifact@") } || {}
check.call(
  download == {
    "name" => "Download verified release artifact",
    "uses" => "actions/download-artifact@#{download_sha}",
    "with" => {
      "name" => "Xcodes-${{ needs.package.outputs.release_tag }}",
      "path" => "Product/${{ needs.package.outputs.release_tag }}",
    },
  },
  "Publish must download packaged tag artifact"
)

validate_publish = publish_step.call("Revalidate downloaded artifact")
check.call(validate_publish["env"] == { "RELEASE_TAG" => "${{ needs.package.outputs.release_tag }}" }, "Publish validation tag changed")
check.call(validate_publish["run"]&.strip == "set -euo pipefail\nbash Scripts/validate_release_artifacts.sh \"Product/$RELEASE_TAG\" \"$RELEASE_TAG\"", "Downloaded artifact must be revalidated")

notes = publish_step.call("Create Sparkle release notes")
check.call(notes["env"] == { "RELEASE_TAG" => "${{ needs.package.outputs.release_tag }}" }, "Release notes tag changed")
check.call(
  notes["run"]&.strip == <<~'SHELL'.strip,
    set -euo pipefail
    release_dir="Product/$RELEASE_TAG"
    readonly release_dir
    signature="$(<"$release_dir/sparkle-signature.txt")"
    readonly signature
    printf 'Signed and notarized Xcodes release.\n\n<!-- sparkle:edSignature=%s -->\n' "$signature" > "$RUNNER_TEMP/release-notes.md"
  SHELL
  "Sparkle release-note signature contract changed"
)

publish_release = publish_step.call("Publish immutable GitHub release")
check.call(publish_release["env"] == { "GH_TOKEN" => "${{ github.token }}", "RELEASE_TAG" => "${{ needs.package.outputs.release_tag }}" }, "Publish token scope or tag changed")
check.call(
  publish_release["run"]&.strip == <<~'SHELL'.strip,
    set -euo pipefail
    readonly release_dir="Product/$RELEASE_TAG"
    if gh release view "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
      echo "Release $RELEASE_TAG already exists; refusing to replace it" >&2
      exit 1
    fi
    gh release create "$RELEASE_TAG" \
      "$release_dir/Xcodes.zip" \
      "$release_dir/Xcodes.zip.sha256" \
      "$release_dir/sparkle-signature.txt" \
      "$release_dir/release-manifest.txt" \
      --repo "$GITHUB_REPOSITORY" \
      --verify-tag \
      --title "Xcodes $RELEASE_TAG" \
      --notes-file "$RUNNER_TEMP/release-notes.md"
  SHELL
  "GitHub release publication contract changed"
)

unless errors.empty?
  warn errors.map { |error| "- #{error}" }.join("\n")
  exit 1
end

puts "CI and release workflow contracts passed"
