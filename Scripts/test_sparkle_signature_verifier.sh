#!/bin/bash

set -euo pipefail

repo_root=""
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly repo_root
test_root=""
test_root="$(mktemp -d "${TMPDIR:-/tmp}/xcodes-sparkle-verifier.XXXXXX")"
readonly test_root
readonly verifier="$test_root/verify-sparkle-signature"
readonly generator="$test_root/generate-sparkle-fixture"

cleanup() {
    rm -rf -- "$test_root"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

expect_failure() {
    local expected="$1"
    shift
    local output="$test_root/failure.log"
    if "$@" > "$output" 2>&1; then
        fail "Verifier unexpectedly accepted tampered fixture"
    fi
    grep -Fq -- "$expected" "$output" || { sed -n '1,60p' "$output" >&2; fail "Missing failure: $expected"; }
}

xcrun swiftc -parse-as-library "$repo_root/Scripts/verify_sparkle_signature.swift" -o "$verifier"
xcrun swiftc "$repo_root/Scripts/generate_sparkle_test_fixture.swift" -o "$generator"

make_fixture() {
    local name="$1"
    local embedded_version="${2:-4.0.4}"
    local embedded_build="${3:-39}"
    local info_mode="${4:-regular}"
    local root="$test_root/$name"
    local release_dir="$root/v4.0.4b39"
    local app_contents="$release_dir/payload/Xcodes.app/Contents"
    mkdir -p "$app_contents"
    "$generator" prepare "$root/private-key" "$root/Info.plist" \
        "$app_contents/Info.plist" "$embedded_version" "$embedded_build"
    printf 'application\n' > "$release_dir/payload/Xcodes.app/content"

    case "$info_mode" in
        regular) ;;
        missing) /bin/rm "$app_contents/Info.plist" ;;
        malformed) printf 'not a plist\n' > "$app_contents/Info.plist" ;;
        symlink)
            /bin/mv "$app_contents/Info.plist" "$app_contents/Info-target.plist"
            /bin/ln -s Info-target.plist "$app_contents/Info.plist"
            ;;
        wrong-id) plutil -replace CFBundleIdentifier -string invalid.example "$app_contents/Info.plist" ;;
        wrong-key) plutil -replace SUPublicEDKey -string AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= "$app_contents/Info.plist" ;;
        *) fail "Unknown Info.plist fixture mode: $info_mode" ;;
    esac

    (cd "$release_dir/payload" && /usr/bin/zip -qry -y "$release_dir/Xcodes.zip" Xcodes.app)
    "$generator" sign "$root/private-key" "$release_dir/Xcodes.zip" \
        "$release_dir/sparkle-signature.txt" "$root/release-body.txt"
    rm -rf -- "$release_dir/payload"
    write_artifact_contract "$root" v4.0.4b39 4.0.4 39
    printf '%s\n' "$root"
}

write_artifact_contract() {
    local root="$1"
    local tag="$2"
    local version="$3"
    local build="$4"
    local release_dir="$root/$tag"
    local checksum
    local signature
    checksum="$(shasum -a 256 "$release_dir/Xcodes.zip" | awk '{ print $1 }')"
    signature="$(<"$release_dir/sparkle-signature.txt")"
    printf '%s  Xcodes.zip\n' "$checksum" > "$release_dir/Xcodes.zip.sha256"
    printf 'tag=%s\nversion=%s\nbuild=%s\nbundle_id=dev.jacobcx.Xcodes\nhelper_bundle_id=dev.jacobcx.Xcodes.Helper\nteam_id=K2648T24P4\nnotarization_id=00000000-0000-0000-0000-000000000000\narchive=Xcodes.zip\nsha256=%s\nsparkle_ed_signature=%s\n' \
        "$tag" "$version" "$build" "$checksum" "$signature" > "$release_dir/release-manifest.txt"
}

duplicate_info_entry() {
    ruby -e '
      path = ARGV.fetch(0)
      target = "Xcodes.app/Contents/Info.plist".b
      data = File.binread(path)
      eocd = data.rindex("PK\x05\x06".b) or raise "missing EOCD"
      entries_on_disk, entries, central_size, central_offset = data.byteslice(eocd + 8, 12).unpack("vvVV")
      position = central_offset
      central_end = central_offset + central_size
      record = nil
      while position < central_end
        raise "invalid central directory" unless data.byteslice(position, 4) == "PK\x01\x02".b
        name_length, extra_length, comment_length = data.byteslice(position + 28, 6).unpack("vvv")
        record_length = 46 + name_length + extra_length + comment_length
        name = data.byteslice(position + 46, name_length)
        record = data.byteslice(position, record_length) if name == target
        position += record_length
      end
      raise "missing target entry" unless record
      data.insert(eocd, record)
      new_eocd = eocd + record.bytesize
      data[new_eocd + 8, 2] = [entries_on_disk + 1].pack("v")
      data[new_eocd + 10, 2] = [entries + 1].pack("v")
      data[new_eocd + 12, 4] = [central_size + record.bytesize].pack("V")
      File.binwrite(path, data)
    ' "$1"
}

rewrite_entry_name() {
    ruby -e '
      path, old_name, new_name = ARGV
      raise "replacement length changed" unless old_name.bytesize == new_name.bytesize
      data = File.binread(path)
      raise "unexpected entry-name occurrence count" unless data.scan(old_name.b).length == 2
      File.binwrite(path, data.gsub(old_name.b, new_name.b))
    ' "$1" "$2" "$3"
}

resign_fixture() {
    local root="$1"
    local tag="${2:-v4.0.4b39}"
    local version="${3:-4.0.4}"
    local build="${4:-39}"
    "$generator" sign "$root/private-key" "$root/$tag/Xcodes.zip" \
        "$root/$tag/sparkle-signature.txt" "$root/release-body.txt"
    write_artifact_contract "$root" "$tag" "$version" "$build"
}

validate_fixture() {
    local root="$1"
    local tag="${2:-v4.0.4b39}"
    SPARKLE_SIGNATURE_VERIFIER="$verifier" bash "$repo_root/Scripts/validate_appcast_release.sh" \
        "$root/$tag" "$tag" "$root/release-body.txt" "$root/Info.plist"
}

fixture="$(make_fixture valid)"
validate_fixture "$fixture" >/dev/null

fixture="$(make_fixture zip-tamper)"
printf 'tamper\n' >> "$fixture/v4.0.4b39/Xcodes.zip"
expect_failure "ZIP checksum validation failed" validate_fixture "$fixture"

fixture="$(make_fixture checksum-tamper)"
printf '%064d  Xcodes.zip\n' 0 > "$fixture/v4.0.4b39/Xcodes.zip.sha256"
expect_failure "ZIP checksum validation failed" validate_fixture "$fixture"

fixture="$(make_fixture signature-tamper)"
ruby -rbase64 -e 'path = ARGV.fetch(0); bytes = Base64.strict_decode64(File.read(path).strip); bytes.setbyte(0, bytes.getbyte(0) ^ 1); File.write(path, Base64.strict_encode64(bytes) + "\n")' \
    "$fixture/v4.0.4b39/sparkle-signature.txt"
signature="$(<"$fixture/v4.0.4b39/sparkle-signature.txt")"
ruby -e 'path, signature = ARGV; text = File.read(path).sub(/^sparkle_ed_signature=.*$/, "sparkle_ed_signature=#{signature}"); File.write(path, text)' \
    "$fixture/v4.0.4b39/release-manifest.txt" "$signature"
ruby -e 'path, signature = ARGV; text = File.read(path).sub(/sparkle:edSignature=[A-Za-z0-9+\/=]+/, "sparkle:edSignature=#{signature}"); File.write(path, text)' \
    "$fixture/release-body.txt" "$signature"
expect_failure "released ZIP failed trusted Sparkle signature verification" validate_fixture "$fixture"

fixture="$(make_fixture body-mismatch)"
ruby -rbase64 -e 'path = ARGV.fetch(0); text = File.read(path); match = text.match(/sparkle:edSignature=([A-Za-z0-9+\/=]+)/); bytes = Base64.strict_decode64(match[1]); bytes.setbyte(0, bytes.getbyte(0) ^ 1); File.write(path, text.sub(match[1], Base64.strict_encode64(bytes)))' \
    "$fixture/release-body.txt"
expect_failure "release body signature does not match signature asset" validate_fixture "$fixture"

fixture="$(make_fixture replayed-future-tag)"
/bin/mv "$fixture/v4.0.4b39" "$fixture/v9.9.9b999"
write_artifact_contract "$fixture" v9.9.9b999 9.9.9 999
expect_failure "embedded app marketing version does not match release tag" validate_fixture "$fixture" v9.9.9b999

fixture="$(make_fixture marketing-mismatch 4.0.5 39)"
expect_failure "embedded app marketing version does not match release tag" validate_fixture "$fixture"

fixture="$(make_fixture build-mismatch 4.0.4 40)"
expect_failure "embedded app build does not match release tag" validate_fixture "$fixture"

fixture="$(make_fixture missing-info 4.0.4 39 missing)"
expect_failure "archive must contain exactly one Xcodes.app/Contents/Info.plist" validate_fixture "$fixture"

fixture="$(make_fixture duplicate-info)"
duplicate_info_entry "$fixture/v4.0.4b39/Xcodes.zip"
resign_fixture "$fixture"
expect_failure "archive must contain exactly one Xcodes.app/Contents/Info.plist" validate_fixture "$fixture"

fixture="$(make_fixture symlink-info 4.0.4 39 symlink)"
expect_failure "embedded app Info.plist must be a regular file" validate_fixture "$fixture"

fixture="$(make_fixture malformed-info 4.0.4 39 malformed)"
expect_failure "embedded app Info.plist is invalid" validate_fixture "$fixture"

fixture="$(make_fixture wrong-app-id 4.0.4 39 wrong-id)"
expect_failure "embedded app identifier does not match maintained fork" validate_fixture "$fixture"

fixture="$(make_fixture wrong-app-key 4.0.4 39 wrong-key)"
expect_failure "embedded app Sparkle public key does not match trusted key" validate_fixture "$fixture"

fixture="$(make_fixture public-key-tamper)"
plutil -replace SUPublicEDKey -string AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= "$fixture/Info.plist"
expect_failure "embedded app Sparkle public key does not match trusted key" validate_fixture "$fixture"

fixture="$(make_fixture unsafe-path)"
printf 'escape\n' > "$fixture/escape"
mkdir -p "$fixture/unsafe-source/deeper"
(cd "$fixture/unsafe-source/deeper" && \
    /usr/bin/zip -q "$fixture/v4.0.4b39/Xcodes.zip" ../../escape)
rm -rf -- "$fixture/unsafe-source"
rm -f -- "$fixture/escape"
resign_fixture "$fixture"
expect_failure "archive contains unsafe entry name" validate_fixture "$fixture"

fixture="$(make_fixture absolute-path)"
rewrite_entry_name "$fixture/v4.0.4b39/Xcodes.zip" Xcodes.app/content /absolute-evil.txt
resign_fixture "$fixture"
expect_failure "archive contains unsafe entry name" validate_fixture "$fixture"

fixture="$(make_fixture backslash-path)"
printf 'escape\n' > "$fixture/bad\\name"
(cd "$fixture" && /usr/bin/zip -q v4.0.4b39/Xcodes.zip 'bad\name')
rm -f -- "$fixture/bad\\name"
resign_fixture "$fixture"
expect_failure "archive contains unsafe entry name" validate_fixture "$fixture"

fixture="$(make_fixture control-path)"
control_name=$'bad\nname'
printf 'escape\n' > "$fixture/$control_name"
(cd "$fixture" && /usr/bin/zip -q v4.0.4b39/Xcodes.zip "$control_name")
rm -f -- "$fixture/$control_name"
resign_fixture "$fixture"
expect_failure "archive contains unsafe entry name" validate_fixture "$fixture"

printf 'Sparkle signature verifier contracts passed.\n'
