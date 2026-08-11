#!/bin/bash

set -euo pipefail

scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly scripts_dir
readonly checker="$scripts_dir/check_localizations.rb"
readonly source_catalog="$scripts_dir/../Xcodes/Resources/Localizable.xcstrings"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/xcodes-localization-tests.XXXXXX")"
readonly test_root

cleanup() {
    rm -rf -- "$test_root"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

expect_failure() {
    local name="$1"
    local mutation="$2"
    local fixture="$test_root/$name.xcstrings"

    cp "$source_catalog" "$fixture"
    ruby -rjson -e "$mutation" "$fixture"
    if ruby "$checker" "$fixture" >/dev/null 2>&1; then
        fail "Localization checker accepted mutation: $name"
    fi
}

ruby "$checker" "$source_catalog" >/dev/null

expect_failure new_missing_translation \
    'path = ARGV.fetch(0); data = JSON.parse(File.read(path)); data["strings"]["CI mutation"] = { "localizations" => { "en" => { "stringUnit" => { "state" => "translated", "value" => "CI mutation" } } } }; File.write(path, JSON.pretty_generate(data))'
expect_failure removed_translation \
    'path = ARGV.fetch(0); data = JSON.parse(File.read(path)); data["strings"]["AutomaticallyCreateSymbolicLink"]["localizations"].delete("de"); File.write(path, JSON.pretty_generate(data))'
expect_failure new_arabic_gap \
    'path = ARGV.fetch(0); data = JSON.parse(File.read(path)); data["strings"]["AutomaticallyCreateSymbolicLink"]["localizations"].delete("ar"); File.write(path, JSON.pretty_generate(data))'
expect_failure new_thai_gap \
    'path = ARGV.fetch(0); data = JSON.parse(File.read(path)); data["strings"]["AutomaticallyCreateSymbolicLink"]["localizations"].delete("th"); File.write(path, JSON.pretty_generate(data))'
expect_failure stale_baseline \
    'path = ARGV.fetch(0); data = JSON.parse(File.read(path)); data["strings"]["AutomaticallyCreateBetaSymbolicLink"]["localizations"]["de"] = { "stringUnit" => { "state" => "translated", "value" => "Beta-Link" } }; File.write(path, JSON.pretty_generate(data))'

checker_fixture="$test_root/omitted-language-checker.rb"
cp "$checker" "$checker_fixture"
perl -0pi -e 's/%w\[ar ca/%w[ca/' "$checker_fixture"
if ruby "$checker_fixture" "$source_catalog" >/dev/null 2>&1; then
    fail "Localization checker accepted omitted supported language: ar"
fi

printf 'Localization mutation contracts passed.\n'
