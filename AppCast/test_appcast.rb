#!/usr/bin/env ruby

require "base64"
require "fileutils"
require "jekyll"
require "json"
require "rexml/document"
require "tmpdir"

source_root = ENV.fetch("APPCAST_SOURCE", File.expand_path(__dir__))
load File.join(source_root, "_plugins", "signature_filter.rb")

def assert(condition, message)
  raise message unless condition
end

def assert_signature_error(filter, body, label, tag)
  filter.sparkle_signature(body, tag)
  raise "#{label} signature unexpectedly passed"
rescue Jekyll::Errors::FatalException
  nil
end

def run_rendered_validator(validator, stable_path, prerelease_path, releases_path, signatures_path)
  system(
    "ruby", validator, stable_path, prerelease_path, releases_path, signatures_path,
    out: File::NULL, err: File::NULL
  )
end

valid_signature = Base64.strict_encode64("\x01" * 64)
second_signature = Base64.strict_encode64("\x02" * 64)
third_signature = Base64.strict_encode64("\x03" * 64)
filter = Object.new.extend(Jekyll::SignatureFilter)

releases = [
  {
    "draft" => false,
    "prerelease" => true,
    "name" => "Prerelease",
    "body" => "Prerelease notes with an untrusted body signature.\n\n<!-- sparkle:edSignature=#{valid_signature} -->",
    "published_at" => "2026-08-11T03:00:00Z",
    "tag_name" => "v1.3.0b35",
    "assets" => [
      {
        "name" => "Xcodes.zip",
        "browser_download_url" => "https://github.com/jacobcxdev/XcodesApp/releases/download/v1.3.0b35/Xcodes.zip",
        "size" => 41,
      },
    ],
  },
  {
    "draft" => false,
    "prerelease" => false,
    "name" => "Stable & <One>",
    "body" => "Stable notes with ]]> boundary.\n\n<!-- sparkle:edSignature=#{second_signature} -->",
    "published_at" => "2026-08-11T02:00:00Z",
    "tag_name" => "v1.2.3b34",
    "assets" => [
      {
        "name" => "Xcodes.zip",
        "browser_download_url" => "https://github.com/jacobcxdev/XcodesApp/releases/download/v1.2.3b34/Xcodes.zip",
        "size" => 30,
      },
    ],
  },
  {
    "draft" => false,
    "prerelease" => false,
    "name" => "Older stable",
    "body" => "Older notes.",
    "published_at" => "2026-08-11T01:00:00Z",
    "tag_name" => "v1.2.2b33",
    "assets" => [
      {
        "name" => "Xcodes.zip",
        "browser_download_url" => "https://github.com/jacobcxdev/XcodesApp/releases/download/v1.2.2b33/Xcodes.zip",
        "size" => 29,
      },
    ],
  },
]
signatures = {
  "v1.2.2b33" => third_signature,
  "v1.2.3b34" => valid_signature,
  "v1.3.0b35" => second_signature,
}

Dir.mktmpdir("xcodes-appcast-test.") do |fixture_root|
  signature_map_path = File.join(fixture_root, "validated-signatures.json")
  File.write(signature_map_path, JSON.generate(signatures))
  ENV["VALIDATED_RELEASE_SIGNATURES_FILE"] = signature_map_path

  assert(
    filter.sparkle_signature("body content is not a signature authority", "v1.2.3b34") == valid_signature,
    "Validated signature map was not authoritative"
  )
  assert_signature_error(filter, "<!-- sparkle:edSignature=#{valid_signature} -->", "Unknown tag", "v9.9.9b999")

  FileUtils.mkdir_p(File.join(fixture_root, "_includes"))
  FileUtils.mkdir_p(File.join(fixture_root, "_data"))
  FileUtils.cp(File.join(source_root, "_includes", "appcast.inc"), File.join(fixture_root, "_includes"))
  FileUtils.cp(File.join(source_root, "appcast.xml"), fixture_root)
  FileUtils.cp(File.join(source_root, "appcast-prereleases.xml"), fixture_root)
  releases_path = File.join(fixture_root, "_data", "validated_releases.json")
  File.write(releases_path, JSON.pretty_generate(releases))

  destination = File.join(fixture_root, "_site")
  config = Jekyll.configuration(
    "source" => fixture_root,
    "destination" => destination,
    "disable_disk_cache" => true,
    "plugins" => [],
    "quiet" => true,
    "title" => "Xcodes fixture"
  )
  Jekyll::Site.new(config).process

  stable_path = File.join(destination, "appcast.xml")
  prerelease_path = File.join(destination, "appcast-prereleases.xml")
  stable_xml = File.read(stable_path)
  prerelease_xml = File.read(prerelease_path)
  stable = REXML::Document.new(stable_xml)
  prerelease = REXML::Document.new(prerelease_xml)

  stable_items = REXML::XPath.match(stable, "//item")
  prerelease_items = REXML::XPath.match(prerelease, "//item")
  assert(
    stable_items.map { |item| item.elements["title"].text } == ["Stable & <One>", "Older stable"],
    "Stable feed routing failed"
  )
  assert(
    prerelease_items.map { |item| item.elements["title"].text } == ["Prerelease", "Stable & <One>", "Older stable"],
    "Prerelease feed routing failed"
  )

  enclosure = stable_items.first.elements["enclosure"]
  assert(
    enclosure.attributes["url"] == "https://github.com/jacobcxdev/XcodesApp/releases/download/v1.2.3b34/Xcodes.zip",
    "Validated Xcodes.zip URL changed"
  )
  assert(enclosure.attributes["sparkle:version"] == "34", "Build version extraction failed")
  assert(enclosure.attributes["sparkle:shortVersionString"] == "1.2.3", "Marketing version extraction failed")
  assert(enclosure.attributes["sparkle:edSignature"] == valid_signature, "Validator signature map was not used")
  prerelease_enclosure = prerelease_items.first.elements["enclosure"]
  assert(prerelease_enclosure.attributes["sparkle:edSignature"] == second_signature, "Prerelease signature map was not used")
  assert(stable_xml.include?("Stable notes with ]]&gt; boundary."), "CDATA boundary was not escaped")

  rendered_validator = File.expand_path("../Scripts/validate_rendered_appcast.rb", __dir__)
  assert(
    run_rendered_validator(rendered_validator, stable_path, prerelease_path, releases_path, signature_map_path),
    "Validated release-set rendering failed"
  )

  extra_path = File.join(destination, "extra-appcast.xml")
  extra_item = <<~XML
    <item><title>Unvalidated</title><description>poison</description><pubDate>Tue, 11 Aug 2026 04:00:00 +0000</pubDate>
    <enclosure url="https://example.invalid/Xcodes.zip" sparkle:version="999" sparkle:shortVersionString="9.9.9" sparkle:edSignature="#{valid_signature}" length="1" type="application/octet-stream" /></item>
  XML
  File.write(extra_path, stable_xml.sub("</channel>", "#{extra_item}</channel>"))
  assert(
    !run_rendered_validator(rendered_validator, extra_path, prerelease_path, releases_path, signature_map_path),
    "Extra unvalidated release unexpectedly rendered"
  )

  missing_path = File.join(destination, "missing-appcast.xml")
  missing_document = REXML::Document.new(stable_xml)
  missing_document.root.elements["channel"].delete_element("item")
  File.write(missing_path, missing_document.to_s)
  assert(
    !run_rendered_validator(rendered_validator, missing_path, prerelease_path, releases_path, signature_map_path),
    "Missing validated release was not detected"
  )
end

puts "Appcast fixture tests passed"
