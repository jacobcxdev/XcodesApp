#!/usr/bin/env ruby

require "yaml"

repo_root = File.expand_path("..", __dir__)
ci_path = File.join(repo_root, ".github/workflows/ci.yml")
release_path = File.join(repo_root, ".github/workflows/release.yml")
release_drafter_path = File.join(repo_root, ".github/workflows/release-drafter.yml")
releasing_docs_path = File.join(repo_root, "docs/RELEASING.md")
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
release_drafter = load_workflow.call(release_drafter_path)
workflows = Dir[File.join(repo_root, ".github/workflows/*.{yml,yaml}")].to_h do |path|
  [path, load_workflow.call(path)]
end

checkout_sha = "3d3c42e5aac5ba805825da76410c181273ba90b1"
upload_sha = "043fb46d1a93c77aae656e7c1c64a875d1fc6a0a"
download_sha = "3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c"
ruby_sha = "95ef2b042f9d7a56d8268cba8559e2842e2ad01b"
repository_guard = "github.repository == 'jacobcxdev/XcodesApp'"
package_guard = "github.repository == 'jacobcxdev/XcodesApp' && github.ref == format('refs/tags/{0}', inputs.release_tag || github.ref_name)"

all_uses = lambda do |workflow|
  workflow.fetch("jobs", {}).values.flat_map do |job|
    [job["uses"], *job.fetch("steps", []).filter_map { |step| step["uses"] }].compact
  end
end

workflows.each do |path, workflow|
  all_uses.call(workflow).each do |uses|
    check.call(
      uses == "./.github/workflows/appcast.yml" ||
        uses == "./action-checkout/actions/publish-appcast" ||
        uses.match?(/\A[^@]+@[0-9a-f]{40}\z/),
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
check.call(verify.keys.sort == %w[if permissions runs-on steps timeout-minutes], "Unexpected CI job capability")
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
    "name" => "Setup Ruby and appcast dependencies",
    "uses" => "ruby/setup-ruby@#{ruby_sha}",
    "env" => { "BUNDLE_FROZEN" => "true" },
    "with" => {
      "ruby-version" => "3.3",
      "bundler" => "4.0.16",
      "bundler-cache" => true,
      "working-directory" => "AppCast",
    },
  },
  {
    "name" => "Validate repository contracts",
    "run" => <<~'SHELL'.strip,
      set -euo pipefail
      bash Scripts/check_fork_identity.sh
      bash Scripts/test_fork_identity_guard.sh
      bash Scripts/check_appcast_identity.sh
      bash Scripts/test_appcast_contracts.sh
      bash Scripts/test_acknowledgements_generator.sh
      bash Scripts/test_sparkle_signature_verifier.sh
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
      swift run --package-path "$checkout" swiftpolyglot "ar,ca,de,el,es,fi,fr,hi,it,ja,ko,nl,pl,pt-BR,ru,th,tr,uk,zh-Hans,zh-Hant"
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

check.call(package["if"] == package_guard, "Package job must be restricted to fork repository and exact tag ref")
check.call(package["runs-on"] == "macos-26", "Package runner must be macos-26")
check.call(package["timeout-minutes"] == 90, "Package timeout must remain bounded")
check.call(package["environment"] == "release", "Package job must use protected release environment")
check.call(package["permissions"] == { "contents" => "read" }, "Package job must not receive write permission")
check.call(package.keys.sort == %w[environment if outputs permissions runs-on steps timeout-minutes], "Unexpected package job capability")
check.call(
  package["outputs"] == {
    "release_tag" => "${{ steps.release.outputs.tag }}",
    "package_sha" => "${{ steps.release.outputs.sha }}",
  },
  "Package tag or immutable SHA output changed"
)

check.call(publish["if"] == repository_guard, "Publish job must be restricted to fork repository")
check.call(publish["needs"] == "package", "Publish must require packaged artifact")
check.call(publish["runs-on"] == "ubuntu-latest", "Publish runner changed")
check.call(publish["timeout-minutes"] == 15, "Publish timeout must remain bounded")
check.call(publish["permissions"] == { "contents" => "write" }, "Publish alone must receive contents: write")
check.call(publish["environment"].nil?, "Publish job must not inherit release environment secrets")
check.call(publish.keys.sort == %w[if needs outputs permissions runs-on steps timeout-minutes], "Unexpected publish job capability")
check.call(!YAML.dump(publish).match?(/secrets\.|DEVELOPER_ID|APP_STORE_CONNECT|SPARKLE_PRIVATE|RELEASE_KEYCHAIN/), "Publish job must not access release secrets")
check.call(publish["outputs"] == { "release_tag" => "${{ needs.package.outputs.release_tag }}" }, "Publish tag output changed")

check.call(
  appcast == {
    "if" => repository_guard,
    "needs" => "publish",
    "permissions" => { "contents" => "read" },
    "uses" => "./.github/workflows/appcast.yml",
    "with" => { "tag" => "${{ needs.publish.outputs.release_tag }}" },
    "secrets" => { "INDEX_REPO_TOKEN" => "${{ secrets.INDEX_REPO_TOKEN }}" },
  },
  "Release must invoke local appcast workflow with exact tag and central publication token"
)
check.call(!YAML.dump(appcast).match?(/secrets:\s*inherit|continue-on-error/), "Appcast caller must not inherit all secrets or suppress failures")

expected_secrets = {
  "CERTIFICATE_P12_BASE64" => "${{ secrets.DEVELOPER_ID_APPLICATION_P12_BASE64 }}",
  "CERTIFICATE_P12_PASSWORD" => "${{ secrets.DEVELOPER_ID_APPLICATION_P12_PASSWORD }}",
  "KEYCHAIN_PASSWORD" => "${{ secrets.RELEASE_KEYCHAIN_PASSWORD }}",
  "NOTARY_KEY_ID_VALUE" => "${{ secrets.APP_STORE_CONNECT_API_KEY_ID }}",
  "NOTARY_ISSUER_ID_VALUE" => "${{ secrets.APP_STORE_CONNECT_API_ISSUER_ID }}",
  "NOTARY_PRIVATE_KEY_VALUE" => "${{ secrets.APP_STORE_CONNECT_API_PRIVATE_KEY }}",
  "SPARKLE_PRIVATE_KEY_VALUE" => "${{ secrets.SPARKLE_PRIVATE_KEY }}",
}

expected_package_steps = [
  {
    "name" => "Checkout immutable release tag",
    "uses" => "actions/checkout@#{checkout_sha}",
    "with" => {
      "ref" => "${{ inputs.release_tag || github.ref_name }}",
      "fetch-depth" => 0,
      "persist-credentials" => false,
    },
  },
  {
    "name" => "Verify immutable release authority",
    "id" => "release",
    "env" => { "RELEASE_TAG" => "${{ inputs.release_tag || github.ref_name }}" },
    "run" => <<~'SHELL'.strip,
      set -euo pipefail
      [[ "$RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+b(0|[1-9][0-9]*)$ ]] || { echo "Release tag must match vX.Y.ZbN exactly" >&2; exit 1; }
      [[ "$GITHUB_REF" == "refs/tags/$RELEASE_TAG" ]] || { echo "Workflow must run from refs/tags/$RELEASE_TAG; dispatch with --ref $RELEASE_TAG" >&2; exit 1; }
      git fetch --force --no-tags origin \
        "+refs/heads/main:refs/remotes/origin/main" \
        "+refs/tags/$RELEASE_TAG:refs/tags/$RELEASE_TAG"
      package_sha="$(git rev-parse 'HEAD^{commit}')"
      readonly package_sha
      [[ "$package_sha" == "$(git rev-list -n 1 "$RELEASE_TAG")" ]] || { echo "Tag does not point at checked-out commit" >&2; exit 1; }
      git tag --points-at HEAD | grep -Fxq -- "$RELEASE_TAG"
      git merge-base --is-ancestor "$package_sha" origin/main || { echo "Release commit is not on origin/main" >&2; exit 1; }
      printf 'tag=%s\nsha=%s\n' "$RELEASE_TAG" "$package_sha" >> "$GITHUB_OUTPUT"
    SHELL
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
    "name" => "Import protected release credentials",
    "env" => expected_secrets,
    "run" => <<~'SHELL'.strip,
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
  },
  {
    "name" => "Build, sign, notarize, and package",
    "env" => { "RELEASE_TAG" => "${{ steps.release.outputs.tag }}" },
    "run" => "set -euo pipefail\nbash Scripts/package_release.sh \"$RELEASE_TAG\"",
  },
  {
    "name" => "Validate release artifact contract",
    "env" => { "RELEASE_TAG" => "${{ steps.release.outputs.tag }}" },
    "run" => "set -euo pipefail\nbash Scripts/validate_release_artifacts.sh \"Product/$RELEASE_TAG\" \"$RELEASE_TAG\"",
  },
  {
    "name" => "Upload verified release artifact",
    "uses" => "actions/upload-artifact@#{upload_sha}",
    "with" => {
      "name" => "Xcodes-${{ steps.release.outputs.tag }}",
      "path" => "Product/${{ steps.release.outputs.tag }}",
      "if-no-files-found" => "error",
      "retention-days" => 7,
    },
  },
  {
    "name" => "Remove release credentials",
    "if" => "always()",
    "run" => <<~'SHELL'.strip,
      set +e
      security default-keychain -d user -s login.keychain-db
      security list-keychains -d user -s login.keychain-db
      security delete-keychain "$RUNNER_TEMP/release.keychain-db"
      rm -f -- "$RUNNER_TEMP/release-certificate.p12" "$RUNNER_TEMP"/AuthKey_*.p8 "$RUNNER_TEMP/sparkle-private-key"
    SHELL
  },
]

expected_publish_steps = [
  {
    "name" => "Checkout packaged commit",
    "uses" => "actions/checkout@#{checkout_sha}",
    "with" => {
      "ref" => "${{ needs.package.outputs.package_sha }}",
      "fetch-depth" => 0,
      "persist-credentials" => false,
    },
  },
  {
    "name" => "Verify packaged release authority",
    "env" => {
      "PACKAGE_SHA" => "${{ needs.package.outputs.package_sha }}",
      "RELEASE_TAG" => "${{ needs.package.outputs.release_tag }}",
    },
    "run" => <<~'SHELL'.strip,
      set -euo pipefail
      git fetch --force --no-tags origin "+refs/tags/$RELEASE_TAG:refs/tags/$RELEASE_TAG"
      [[ "$(git rev-parse 'HEAD^{commit}')" == "$PACKAGE_SHA" ]] || { echo "Publish checkout does not match packaged commit" >&2; exit 1; }
      [[ "$(git rev-list -n 1 "$RELEASE_TAG")" == "$PACKAGE_SHA" ]] || { echo "Release tag moved after packaging" >&2; exit 1; }
    SHELL
  },
  {
    "name" => "Download verified release artifact",
    "uses" => "actions/download-artifact@#{download_sha}",
    "with" => {
      "name" => "Xcodes-${{ needs.package.outputs.release_tag }}",
      "path" => "Product/${{ needs.package.outputs.release_tag }}",
    },
  },
  {
    "name" => "Revalidate downloaded artifact",
    "env" => { "RELEASE_TAG" => "${{ needs.package.outputs.release_tag }}" },
    "run" => "set -euo pipefail\nbash Scripts/validate_release_artifacts.sh \"Product/$RELEASE_TAG\" \"$RELEASE_TAG\"",
  },
  {
    "name" => "Create Sparkle release notes",
    "env" => { "RELEASE_TAG" => "${{ needs.package.outputs.release_tag }}" },
    "run" => <<~'SHELL'.strip,
      set -euo pipefail
      release_dir="Product/$RELEASE_TAG"
      readonly release_dir
      signature="$(<"$release_dir/sparkle-signature.txt")"
      readonly signature
      printf 'Signed and notarized Xcodes release.\n\n<!-- sparkle:edSignature=%s -->\n' "$signature" > "$RUNNER_TEMP/release-notes.md"
    SHELL
  },
  {
    "name" => "Publish immutable GitHub release",
    "env" => {
      "GH_TOKEN" => "${{ github.token }}",
      "PACKAGE_SHA" => "${{ needs.package.outputs.package_sha }}",
      "RELEASE_TAG" => "${{ needs.package.outputs.release_tag }}",
    },
    "run" => <<~'SHELL'.strip,
      set -euo pipefail
      readonly release_dir="Product/$RELEASE_TAG"
      if gh release view "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
        echo "Release $RELEASE_TAG already exists; refusing to replace it" >&2
        exit 1
      fi
      git fetch --force --no-tags origin "+refs/tags/$RELEASE_TAG:refs/tags/$RELEASE_TAG"
      [[ "$(git rev-parse 'HEAD^{commit}')" == "$PACKAGE_SHA" ]] || { echo "Publish checkout changed after validation" >&2; exit 1; }
      [[ "$(git rev-list -n 1 "$RELEASE_TAG")" == "$PACKAGE_SHA" ]] || { echo "Release tag moved after validation" >&2; exit 1; }
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
  },
]

package_steps = normalise_steps.call(package.fetch("steps", []))
publish_steps = normalise_steps.call(publish.fetch("steps", []))
check.call(package_steps == expected_package_steps, "Package steps must exactly match audited controls")
check.call(publish_steps == expected_publish_steps, "Publish steps must exactly match audited controls")
check.call(package_steps.index { |step| step["name"] == "Verify immutable release authority" } < package_steps.index { |step| step["name"] == "Import protected release credentials" }, "Release authority must be verified before credential material")

check.call(release_drafter.keys.map(&:to_s).sort == %w[concurrency jobs name on permissions], "Release drafter top-level capability changed")
check.call(
  release_drafter["on"] == {
    "workflow_dispatch" => nil,
    "push" => { "branches" => ["main"] },
  },
  "Release drafter triggers changed"
)
check.call(release_drafter["permissions"] == { "contents" => "read" }, "Release drafter top-level permissions changed")
check.call(
  release_drafter["concurrency"] == {
    "group" => "release-drafter-${{ github.ref }}",
    "cancel-in-progress" => true,
  },
  "Release drafter concurrency changed"
)
check.call(
  release_drafter.fetch("jobs", {}) == {
    "update_release_draft" => {
      "if" => repository_guard,
      "runs-on" => "ubuntu-latest",
      "timeout-minutes" => 10,
      "permissions" => { "contents" => "write" },
      "steps" => [
        {
          "uses" => "release-drafter/release-drafter@34d80673e067bdc0c24568d3af899c216adcfaa9",
          "env" => { "GITHUB_TOKEN" => "${{ github.token }}" },
        },
      ],
    },
  },
  "Release drafter job must exactly match audited controls"
)
check.call(File.read(release_drafter_path).include?("# v7.7.0"), "Release drafter action version comment must match v7.7.0")

releasing_docs = File.file?(releasing_docs_path) ? File.read(releasing_docs_path) : ""
check.call(releasing_docs.include?("environment protection rule must allow only protected tags matching `v*`"), "Release guide must require exact environment tag restrictions")
check.call(releasing_docs.include?("`workflow_dispatch` reruns must use `--ref v4.0.5b47`"), "Release guide must document tag-ref manual dispatch")
check.call(
  releasing_docs.include?("gh workflow run appcast.yml --ref v4.0.5b47 -f tag=v4.0.5b47"),
  "Release guide must document exact tag-bound appcast dispatch"
)
check.call(
  releasing_docs.include?("Reusable workflows receive the caller's `github.ref`; the appcast build requires that ref to equal `refs/tags/<tag>`"),
  "Release guide must document reusable workflow tag-ref semantics"
)
check.call(
  releasing_docs.include?("Rerun the same appcast tag only for transient infrastructure or central-host configuration failures when tagged source is unchanged."),
  "Release guide must limit same-tag appcast reruns to transient failures"
)
check.call(
  releasing_docs.include?("Any workflow, validator, or source fix requires an incremented build number, a new immutable `vX.Y.ZbN` tag, and a new release."),
  "Release guide must require a new release for source fixes"
)
check.call(!releasing_docs.include?("after fixing its source"), "Release guide must not permit same-tag source fixes")
check.call(releasing_docs.include?("XcodesApp must not enable GitHub Pages or maintain a `gh-pages` branch."), "Release guide must forbid app-owned Pages")
check.call(releasing_docs.include?("https://docs.jacobcx.dev/repo/1330187036/updates/appcast.xml"), "Release guide must document stable-ID central feed")

unless errors.empty?
  warn errors.map { |error| "- #{error}" }.join("\n")
  exit 1
end

puts "CI and release workflow contracts passed"
