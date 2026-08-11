#!/bin/bash

set -euo pipefail

default_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly default_repo_root
readonly repo_root="${1:-$default_repo_root}"
readonly app_info_plist="$repo_root/Xcodes/Resources/Info.plist"
readonly updates_source="$repo_root/Xcodes/Frontend/Preferences/UpdatesPreferencePane.swift"
readonly appcast_config="$repo_root/AppCast/_config.yml"
readonly appcast_gemfile="$repo_root/AppCast/Gemfile"
readonly appcast_template="$repo_root/AppCast/_includes/appcast.inc"
readonly appcast_filter="$repo_root/AppCast/_plugins/signature_filter.rb"
readonly appcast_test="$repo_root/AppCast/test_appcast.rb"
readonly appcast_workflow="$repo_root/.github/workflows/appcast.yml"
readonly workflow_check="$repo_root/Scripts/check_appcast_workflow.rb"
readonly downloaded_release_validator="$repo_root/Scripts/validate_appcast_release.sh"
readonly release_history_validator="$repo_root/Scripts/validate_appcast_history.rb"
readonly archive_inspector="$repo_root/Scripts/inspect_app_archive.rb"
readonly signature_verifier="$repo_root/Scripts/verify_sparkle_signature.swift"
readonly signature_extractor="$repo_root/Scripts/extract_sparkle_signature.rb"
readonly rendered_appcast_validator="$repo_root/Scripts/validate_rendered_appcast.rb"
readonly lockfile="$repo_root/AppCast/Gemfile.lock"

readonly stable_feed="https://jacobcxdev.github.io/XcodesApp/appcast.xml"
readonly prerelease_feed="https://jacobcxdev.github.io/XcodesApp/appcast_pre.xml"
readonly sparkle_public_key="CbToeJaT+HbP9oQAtNtKtBABQhYYisM4Y/fI8q2gcF8="

for required_file in \
    "$app_info_plist" \
    "$updates_source" \
    "$appcast_config" \
    "$appcast_gemfile" \
    "$appcast_template" \
    "$appcast_filter" \
    "$appcast_test" \
    "$appcast_workflow" \
    "$workflow_check" \
    "$downloaded_release_validator" \
    "$release_history_validator" \
    "$archive_inspector" \
    "$signature_verifier" \
    "$signature_extractor" \
    "$rendered_appcast_validator" \
    "$lockfile"; do
    if [[ ! -f "$required_file" ]]; then
        echo "Missing appcast contract file: ${required_file#"$repo_root/"}" >&2
        exit 1
    fi
done

# shellcheck disable=SC2016 # Validator variables must remain literal in the contract.
inspector_call='ruby "$repo_root/Scripts/inspect_app_archive.rb" "$release_dir/Xcodes.zip" >/dev/null'
inspector_call_count="$(grep -Fxc -- "$inspector_call" "$downloaded_release_validator" || true)"
readonly inspector_call inspector_call_count
if [[ "$inspector_call_count" -ne 1 ]]; then
    echo "Downloaded release validator must invoke the archive inspector exactly once" >&2
    exit 1
fi

app_info=$(plutil -convert json -o - "$app_info_plist")
jq -e --arg stable_feed "$stable_feed" --arg sparkle_public_key "$sparkle_public_key" \
    '.SUFeedURL == $stable_feed and .SUPublicEDKey == $sparkle_public_key' \
    <<< "$app_info" >/dev/null

for expected_line in \
    "static let appcast = \"$stable_feed\"" \
    "static let prereleaseAppcast = \"$prerelease_feed\""; do
    count=$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' "$updates_source" | grep -Fxc -- "$expected_line" || true)
    if [[ "$count" -ne 1 ]]; then
        echo "Unexpected updater feed assignment: $expected_line" >&2
        exit 1
    fi
done

config_json=$(ruby -rjson -ryaml -e 'print JSON.generate(YAML.safe_load_file(ARGV.fetch(0), aliases: false))' "$appcast_config")
jq -e \
    '.repository == "jacobcxdev/XcodesApp"
        and .url == "https://jacobcxdev.github.io"
        and .baseurl == "/XcodesApp"
        and .plugins == []' \
    <<< "$config_json" >/dev/null

validated_source_count="$(grep -Foc -- 'site.data.validated_releases' "$appcast_template" || true)"
signature_map_count="$(grep -Foc -- 'VALIDATED_RELEASE_SIGNATURES_FILE' "$appcast_filter" || true)"
readonly validated_source_count signature_map_count
[[ "$validated_source_count" == 1 ]] || { echo "Appcast template must use validated release data exactly once" >&2; exit 1; }
[[ "$signature_map_count" == 1 ]] || { echo "Appcast filter must use the validated signature map exactly once" >&2; exit 1; }
if grep -Fq -- 'site.github.releases' "$appcast_template" || \
    grep -Fq -- 'jekyll-github-metadata' "$appcast_config" "$appcast_gemfile"; then
    echo "Raw GitHub release metadata must not reach appcast rendering" >&2
    exit 1
fi

ruby "$workflow_check" "$appcast_workflow" "$lockfile"

if command -v actionlint >/dev/null 2>&1; then
    actionlint "$appcast_workflow"
fi

if grep -R -n -E -- \
    'www\.xcodes\.app/appcast|SEcz0vgUSeBTOoAXYe\+64zea95G6lIf5NgzFs3InYJQ=|github\.com/XcodesOrg/XcodesApp' \
    "$app_info_plist" "$updates_source" "$appcast_config" "$appcast_template" "$appcast_filter" "$appcast_workflow"; then
    echo "Upstream-owned Sparkle feed, key, or repository remains" >&2
    exit 1
fi

echo "Appcast identity check passed"
