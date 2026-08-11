#!/bin/bash

set -euo pipefail

repo_root=""
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly repo_root
test_root=""
test_root="$(mktemp -d "${TMPDIR:-/tmp}/xcodes-appcast-history.XXXXXX")"
readonly test_root
readonly generator="$test_root/generate-sparkle-fixture"
readonly verifier="$test_root/verify-sparkle-signature"
readonly history_repo="$test_root/repository"
readonly origin_repo="$test_root/origin.git"
readonly asset_root="$test_root/assets"
readonly fake_bin="$test_root/bin"
readonly expected_tag="v4.0.4b39"

cleanup() {
    rm -rf -- "$test_root"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

git_in_history() {
    git -C "$history_repo" "$@"
}

make_release_assets() {
    local tag="$1"
    local version="$2"
    local build="$3"
    local release_dir="$asset_root/$tag"
    local payload="$release_dir/payload/Xcodes.app/Contents"
    local checksum
    local signature

    mkdir -p "$payload"
    cp "$test_root/app-template.plist" "$payload/Info.plist"
    plutil -replace CFBundleShortVersionString -string "$version" "$payload/Info.plist"
    plutil -replace CFBundleVersion -string "$build" "$payload/Info.plist"
    printf 'application %s\n' "$tag" > "$release_dir/payload/Xcodes.app/content"
    (cd "$release_dir/payload" && /usr/bin/zip -qry "$release_dir/Xcodes.zip" Xcodes.app)
    "$generator" sign "$test_root/private-key" "$release_dir/Xcodes.zip" \
        "$release_dir/sparkle-signature.txt" "$release_dir/release-body.txt"
    rm -rf -- "$release_dir/payload"
    checksum="$(shasum -a 256 "$release_dir/Xcodes.zip" | awk '{ print $1 }')"
    signature="$(<"$release_dir/sparkle-signature.txt")"
    printf '%s  Xcodes.zip\n' "$checksum" > "$release_dir/Xcodes.zip.sha256"
    printf 'tag=%s\nversion=%s\nbuild=%s\nbundle_id=dev.jacobcx.Xcodes\nhelper_bundle_id=dev.jacobcx.Xcodes.Helper\nteam_id=K2648T24P4\nnotarization_id=00000000-0000-0000-0000-000000000000\narchive=Xcodes.zip\nsha256=%s\nsparkle_ed_signature=%s\n' \
        "$tag" "$version" "$build" "$checksum" "$signature" > "$release_dir/release-manifest.txt"
}

release_json() {
    local tag="$1"
    local prerelease="$2"
    local published_at="$3"
    local body
    local zip_size
    local checksum_size
    local signature_size
    local manifest_size
    body="$(<"$asset_root/$tag/release-body.txt")"
    zip_size="$(stat -f %z "$asset_root/$tag/Xcodes.zip")"
    checksum_size="$(stat -f %z "$asset_root/$tag/Xcodes.zip.sha256")"
    signature_size="$(stat -f %z "$asset_root/$tag/sparkle-signature.txt")"
    manifest_size="$(stat -f %z "$asset_root/$tag/release-manifest.txt")"
    jq -n \
        --arg tag "$tag" \
        --arg name "Release $tag" \
        --arg body "$body" \
        --arg published_at "$published_at" \
        --argjson prerelease "$prerelease" \
        --argjson zip_size "$zip_size" \
        --argjson checksum_size "$checksum_size" \
        --argjson signature_size "$signature_size" \
        --argjson manifest_size "$manifest_size" \
        '{
          tag_name: $tag,
          name: $name,
          body: $body,
          draft: false,
          prerelease: $prerelease,
          published_at: $published_at,
          assets: [
            {name: "Xcodes.zip", size: $zip_size, browser_download_url: ("https://github.com/jacobcxdev/XcodesApp/releases/download/" + $tag + "/Xcodes.zip")},
            {name: "Xcodes.zip.sha256", size: $checksum_size, browser_download_url: "https://example.invalid/checksum"},
            {name: "sparkle-signature.txt", size: $signature_size, browser_download_url: "https://example.invalid/signature"},
            {name: "release-manifest.txt", size: $manifest_size, browser_download_url: "https://example.invalid/manifest"}
          ]
        }'
}

write_release_pages() {
    local destination="$1"
    shift
    jq -s '[.[0:2], .[2:]]' "$@" > "$destination"
}

run_validator() {
    local release_json_path="$1"
    local output_root="$2"
    mkdir -p "$output_root/releases"
    PATH="$fake_bin:$PATH" \
        GH_FIXTURE_JSON="$release_json_path" \
        GH_FIXTURE_ASSETS="${GH_FIXTURE_ASSETS_OVERRIDE:-$asset_root}" \
        GITHUB_REPOSITORY="jacobcxdev/XcodesApp" \
        ruby "$repo_root/Scripts/validate_appcast_history.rb" \
            "$expected_tag" \
            "$output_root/releases" \
            "$output_root/validated-releases.json" \
            "$output_root/validated-signatures.json" \
            "$verifier" \
            "$test_root/trusted.plist" \
            "$history_repo"
}

expect_validation_failure() {
    local label="$1"
    local release_json_path="$2"
    local output_root="$test_root/failure-$label"
    if run_validator "$release_json_path" "$output_root" >/dev/null 2>&1; then
        fail "$label sibling release unexpectedly passed"
    fi
    [[ ! -e "$output_root/validated-releases.json" ]] || fail "$label emitted sanitized releases after failure"
    [[ ! -e "$output_root/validated-signatures.json" ]] || fail "$label emitted signatures after failure"
}

xcrun swiftc -warnings-as-errors "$repo_root/Scripts/generate_sparkle_test_fixture.swift" -o "$generator"
xcrun swiftc -parse-as-library -warnings-as-errors "$repo_root/Scripts/verify_sparkle_signature.swift" -o "$verifier"
"$generator" prepare "$test_root/private-key" "$test_root/trusted.plist" \
    "$test_root/app-template.plist" 4.0.4 39

git init --bare -q "$origin_repo"
git init -q -b main "$history_repo"
git_in_history config user.name "Appcast Test"
git_in_history config user.email "appcast-test@example.invalid"
printf 'old\n' > "$history_repo/history"
git_in_history add history
git_in_history commit -qm "old"
git_in_history tag v4.0.3b38
git_in_history tag v9.9.9b999
printf 'expected\n' > "$history_repo/history"
git_in_history commit -qam "expected"
git_in_history tag "$expected_tag"
printf 'prerelease\n' > "$history_repo/history"
git_in_history commit -qam "prerelease"
git_in_history tag v4.1.0b40
git_in_history remote add origin "$origin_repo"
git_in_history push -q origin main --tags
git_in_history checkout -q --orphan untrusted-history
printf 'untrusted\n' > "$history_repo/history"
git_in_history add history
git_in_history commit -qm "untrusted"
git_in_history tag v8.8.8b888
git_in_history push -q origin v8.8.8b888
git_in_history checkout -q "$expected_tag"
git_in_history fetch -q origin main

make_release_assets v4.0.3b38 4.0.3 38
make_release_assets "$expected_tag" 4.0.4 39
make_release_assets v4.1.0b40 4.1.0 40
make_release_assets v9.9.9b999 4.0.3 38
make_release_assets v8.8.8b888 8.8.8 888
make_release_assets v7.7.7b777 7.7.7 777

mkdir -p "$fake_bin"
cat > "$fake_bin/gh" <<'FAKE_GH'
#!/bin/bash
set -euo pipefail
if [[ "${1:-}" == "api" ]]; then
    [[ "$*" == *"--paginate"* && "$*" == *"--slurp"* ]] || exit 90
    cat "$GH_FIXTURE_JSON"
    exit 0
fi
[[ "${1:-}" == "release" && "${2:-}" == "download" ]] || exit 91
tag="$3"
shift 3
asset=""
destination=""
while (( $# > 0 )); do
    case "$1" in
        --repo) shift 2 ;;
        --pattern) asset="$2"; shift 2 ;;
        --dir) destination="$2"; shift 2 ;;
        *) exit 92 ;;
    esac
done
cp "$GH_FIXTURE_ASSETS/$tag/$asset" "$destination/$asset"
FAKE_GH
chmod 700 "$fake_bin/gh"

release_json v4.1.0b40 true 2026-08-11T03:00:00Z > "$test_root/prerelease.json"
release_json "$expected_tag" false 2026-08-11T02:00:00Z > "$test_root/expected.json"
release_json v4.0.3b38 false 2026-08-11T01:00:00Z > "$test_root/old.json"
write_release_pages "$test_root/valid-pages.json" \
    "$test_root/prerelease.json" "$test_root/expected.json" "$test_root/old.json"

run_validator "$test_root/valid-pages.json" "$test_root/valid"
jq -e '[.[].tag_name] == ["v4.1.0b40", "v4.0.4b39", "v4.0.3b38"]' \
    "$test_root/valid/validated-releases.json" >/dev/null || fail "validated history order changed"
jq -e 'keys == ["v4.0.3b38", "v4.0.4b39", "v4.1.0b40"]' \
    "$test_root/valid/validated-signatures.json" >/dev/null || fail "validated signature map is incomplete"
ruby -rbase64 -rjson -e '
  signatures = JSON.parse(File.read(ARGV.fetch(0)))
  valid = signatures.values.all? do |signature|
    decoded = Base64.strict_decode64(signature)
    decoded.bytesize == 64 && Base64.strict_encode64(decoded) == signature
  rescue ArgumentError
    false
  end
  exit(valid ? 0 : 1)
' "$test_root/valid/validated-signatures.json" || fail "validated signature map contains non-canonical signatures"

release_json v9.9.9b999 false 2026-08-11T04:00:00Z > "$test_root/replayed.json"
write_release_pages "$test_root/replayed-pages.json" \
    "$test_root/replayed.json" "$test_root/expected.json" "$test_root/old.json"
expect_validation_failure replayed-version "$test_root/replayed-pages.json"

release_json v8.8.8b888 false 2026-08-11T04:00:00Z > "$test_root/untrusted-tag.json"
write_release_pages "$test_root/untrusted-tag-pages.json" \
    "$test_root/untrusted-tag.json" "$test_root/expected.json" "$test_root/old.json"
expect_validation_failure non-main-tag "$test_root/untrusted-tag-pages.json"

release_json v7.7.7b777 false 2026-08-11T04:00:00Z > "$test_root/missing-tag.json"
write_release_pages "$test_root/missing-tag-pages.json" \
    "$test_root/missing-tag.json" "$test_root/expected.json" "$test_root/old.json"
expect_validation_failure missing-tag "$test_root/missing-tag-pages.json"

cp -R "$asset_root" "$test_root/signature-assets"
printf '%088d\n' 0 > "$test_root/signature-assets/v4.0.3b38/sparkle-signature.txt"
GH_FIXTURE_ASSETS_OVERRIDE="$test_root/signature-assets" expect_validation_failure signature "$test_root/valid-pages.json"

cp -R "$asset_root" "$test_root/checksum-assets"
printf '%064d  Xcodes.zip\n' 0 > "$test_root/checksum-assets/v4.0.3b38/Xcodes.zip.sha256"
GH_FIXTURE_ASSETS_OVERRIDE="$test_root/checksum-assets" expect_validation_failure checksum "$test_root/valid-pages.json"

cp "$test_root/old.json" "$test_root/body.json"
jq '.body = "tampered body"' "$test_root/body.json" > "$test_root/body-mutated.json"
write_release_pages "$test_root/body-pages.json" \
    "$test_root/prerelease.json" "$test_root/expected.json" "$test_root/body-mutated.json"
expect_validation_failure body "$test_root/body-pages.json"

printf 'Validated appcast history contracts passed.\n'
