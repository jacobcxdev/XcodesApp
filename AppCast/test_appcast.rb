#!/usr/bin/env ruby

require "base64"
require "fileutils"
require "jekyll"
require "rexml/document"
require "tmpdir"

source_root = ENV.fetch("APPCAST_SOURCE", File.expand_path(__dir__))
load File.join(source_root, "_plugins", "signature_filter.rb")

def assert(condition, message)
  raise message unless condition
end

def assert_signature_error(filter, body, label, tag = nil)
  filter.sparkle_signature(body, tag)
  raise "#{label} signature unexpectedly passed"
rescue Jekyll::Errors::FatalException
  nil
end

valid_signature = Base64.strict_encode64("\x01" * 64)
second_signature = Base64.strict_encode64("\x02" * 64)
filter = Object.new.extend(Jekyll::SignatureFilter)

assert(
  filter.sparkle_signature("Release notes\n\n<!-- sparkle:edSignature=#{valid_signature} -->") == valid_signature,
  "Valid signature was not extracted"
)
assert_signature_error(filter, "Release notes only", "Missing")
assert_signature_error(filter, "<!-- sparkle:edSignature=not-base64 -->", "Invalid Base64")
assert_signature_error(filter, "<!-- sparkle:edSignature=#{Base64.strict_encode64("short")} -->", "Invalid length")
assert_signature_error(filter, "<!-- sparkle:edSignature= #{valid_signature} -->", "Leading whitespace")
assert_signature_error(filter, "<!-- sparkle:edSignature=#{valid_signature[0, 44]}\n#{valid_signature[44..]} -->", "Embedded newline")
assert_signature_error(
  filter,
  "<!-- sparkle:edSignature=#{valid_signature} -->\n<!-- sparkle:edSignature=#{second_signature} -->",
  "Multiple"
)

ENV["VERIFIED_RELEASE_TAG"] = "v1.2.3b34"
ENV["VERIFIED_SPARKLE_SIGNATURE"] = second_signature
assert_signature_error(
  filter,
  "Release notes\n\n<!-- sparkle:edSignature=#{valid_signature} -->",
  "Verified body mismatch",
  "v1.2.3b34"
)
ENV["VERIFIED_SPARKLE_SIGNATURE"] = valid_signature
assert_signature_error(
  filter,
  "<!-- sparkle:edSignature=#{valid_signature} --> <!-- trailing -->",
  "Trailing-comment"
)

releases = [
  {
    "draft" => false,
    "prerelease" => false,
    "name" => "Stable & <One>",
    "body" => "Stable notes with ]]> boundary.\n\n<!-- sparkle:edSignature=#{valid_signature} -->",
    "published_at" => "2026-08-11T00:00:00Z",
    "tag_name" => "v1.2.3b34",
    "assets" => [
      {
        "name" => "Xcodes.dmg",
        "browser_download_url" => "https://example.invalid/Xcodes.dmg",
        "size" => 10,
      },
      {
        "name" => "wrong.zip",
        "browser_download_url" => "https://example.invalid/wrong.zip",
        "size" => 20,
      },
      {
        "name" => "Xcodes.zip",
        "browser_download_url" => "https://example.invalid/Xcodes.zip?download=1&source=test",
        "size" => 30,
      },
    ],
  },
  {
    "draft" => false,
    "prerelease" => true,
    "name" => "Prerelease",
    "body" => "Prerelease notes.\n\n<!-- sparkle:edSignature=#{second_signature} -->",
    "published_at" => "2026-08-11T01:00:00Z",
    "tag_name" => "v1.3b35",
    "assets" => [
      {
        "name" => "Xcodes-prerelease.ZIP",
        "browser_download_url" => "https://example.invalid/Xcodes-prerelease.ZIP",
        "size" => 40,
      },
      {
        "name" => "Xcodes.zip",
        "browser_download_url" => "https://example.invalid/prerelease/Xcodes.zip",
        "size" => 41,
      },
    ],
  },
  {
    "draft" => false,
    "prerelease" => false,
    "name" => "Missing ZIP",
    "body" => "No ZIP.\n\n<!-- sparkle:edSignature=#{valid_signature} -->",
    "published_at" => "2026-08-11T02:00:00Z",
    "tag_name" => "v1.4b36",
    "assets" => [
      {
        "name" => "wrong.zip",
        "browser_download_url" => "https://example.invalid/wrong.zip",
        "size" => 50,
      },
    ],
  },
]

Dir.mktmpdir("xcodes-appcast-test.") do |fixture_root|
  FileUtils.mkdir_p(File.join(fixture_root, "_includes"))
  FileUtils.cp(File.join(source_root, "_includes", "appcast.inc"), File.join(fixture_root, "_includes"))
  FileUtils.cp(File.join(source_root, "appcast.xml"), fixture_root)
  FileUtils.cp(File.join(source_root, "appcast_pre.xml"), fixture_root)

  destination = File.join(fixture_root, "_site")
  config = Jekyll.configuration(
    "source" => fixture_root,
    "destination" => destination,
    "disable_disk_cache" => true,
    "plugins" => [],
    "quiet" => true,
    "github" => {
      "project_title" => "Xcodes fixture",
      "releases" => releases,
    }
  )
  Jekyll::Site.new(config).process

  stable_xml = File.read(File.join(destination, "appcast.xml"))
  prerelease_xml = File.read(File.join(destination, "appcast_pre.xml"))
  stable = REXML::Document.new(stable_xml)
  prerelease = REXML::Document.new(prerelease_xml)

  stable_items = REXML::XPath.match(stable, "//item")
  prerelease_items = REXML::XPath.match(prerelease, "//item")
  assert(stable_items.map { |item| item.elements["title"].text } == ["Stable & <One>"], "Stable feed routing failed")
  assert(
    prerelease_items.map { |item| item.elements["title"].text } == ["Stable & <One>", "Prerelease"],
    "Prerelease feed routing failed"
  )

  enclosure = stable_items.first.elements["enclosure"]
  assert(enclosure.attributes["url"] == "https://example.invalid/Xcodes.zip?download=1&source=test", "Exact Xcodes.zip selection failed")
  assert(enclosure.attributes["sparkle:version"] == "34", "Build version extraction failed")
  assert(enclosure.attributes["sparkle:shortVersionString"] == "1.2.3", "Marketing version extraction failed")
  assert(enclosure.attributes["sparkle:edSignature"] == valid_signature, "Signature output changed")
  prerelease_enclosure = prerelease_items.last.elements["enclosure"]
  assert(
    prerelease_enclosure.attributes["url"] == "https://example.invalid/prerelease/Xcodes.zip",
    "Prerelease exact Xcodes.zip selection failed"
  )
  assert(!stable_xml.include?("wrong.zip"), "Non-contract ZIP unexpectedly selected")
  assert(!stable_xml.include?("Missing ZIP"), "Release without ZIP unexpectedly emitted")
  assert(!prerelease_xml.include?("Missing ZIP"), "Release without ZIP unexpectedly emitted in prerelease feed")
  assert(stable_xml.include?("Stable notes with ]]&gt; boundary."), "CDATA boundary was not escaped")

  verified_signature_path = File.join(fixture_root, "verified-signature.txt")
  File.write(verified_signature_path, "#{valid_signature}\n")
  rendered_validator = File.expand_path("../Scripts/validate_rendered_appcast.rb", __dir__)
  assert(
    system("ruby", rendered_validator, File.join(destination, "appcast.xml"), "v1.2.3b34", verified_signature_path, out: File::NULL),
    "Rendered verified-release validation failed"
  )
end

puts "Appcast fixture tests passed"
