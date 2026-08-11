#!/usr/bin/env ruby

require "json"
require "rexml/document"

TAG_PATTERN = /\Av(?<version>[0-9]+\.[0-9]+\.[0-9]+)b(?<build>0|[1-9][0-9]*)\z/

def expected_enclosures(releases, signatures, include_prereleases:)
  releases.filter_map do |release|
    raise "Validated release entry must be an object" unless release.is_a?(Hash)
    next if release.fetch("prerelease") && !include_prereleases

    tag = release.fetch("tag_name")
    match = TAG_PATTERN.match(tag.to_s)
    raise "Validated release tag is invalid" unless match
    raise "Validated release draft flag is invalid" unless release["draft"] == false
    assets = release.fetch("assets")
    unless assets.is_a?(Array) && assets.one? && assets.first.is_a?(Hash) && assets.first["name"] == "Xcodes.zip"
      raise "Validated release must contain only Xcodes.zip rendering data"
    end
    asset = assets.first
    size = asset.fetch("size")
    raise "Validated Xcodes.zip size is invalid" unless size.is_a?(Integer) && size.positive?

    {
      "tag" => tag,
      "version" => match[:version],
      "build" => match[:build],
      "signature" => signatures.fetch(tag),
      "url" => asset.fetch("browser_download_url"),
      "length" => size.to_s,
    }
  end
end

def rendered_enclosures(path)
  document = REXML::Document.new(File.read(path))
  items = REXML::XPath.match(document, "//item")
  all_enclosures = REXML::XPath.match(document, "//enclosure")
  raise "Every rendered item must contain exactly one enclosure" unless all_enclosures.length == items.length

  items.map do |item|
    enclosures = item.get_elements("enclosure")
    raise "Every rendered item must contain exactly one enclosure" unless enclosures.one?
    enclosure = enclosures.first
    version = enclosure.attributes["sparkle:shortVersionString"]
    build = enclosure.attributes["sparkle:version"]
    tag = "v#{version}b#{build}"
    raise "Rendered enclosure tag is invalid" unless TAG_PATTERN.match?(tag)
    {
      "tag" => tag,
      "version" => version,
      "build" => build,
      "signature" => enclosure.attributes["sparkle:edSignature"],
      "url" => enclosure.attributes["url"],
      "length" => enclosure.attributes["length"],
    }
  end
end

stable_path, prerelease_path, releases_path, signatures_path = ARGV
raise "usage: validate_rendered_appcast <stable> <prerelease> <releases-json> <signatures-json>" unless ARGV.length == 4
releases = JSON.parse(File.read(releases_path))
signatures = JSON.parse(File.read(signatures_path))
raise "Validated releases must be an array" unless releases.is_a?(Array)
raise "Validated signatures must be an object" unless signatures.is_a?(Hash)
tags = releases.map { |release| release.is_a?(Hash) ? release["tag_name"] : nil }
raise "Validated release tags must be unique" unless tags.compact.length == releases.length && tags.uniq.length == tags.length
raise "Validated signature map must exactly match releases" unless signatures.keys.sort == tags.sort

stable_expected = expected_enclosures(releases, signatures, include_prereleases: false)
prerelease_expected = expected_enclosures(releases, signatures, include_prereleases: true)
raise "Rendered stable appcast differs from validated releases" unless rendered_enclosures(stable_path) == stable_expected
raise "Rendered prerelease appcast differs from validated releases" unless rendered_enclosures(prerelease_path) == prerelease_expected

puts "Rendered appcasts exactly match #{releases.length} validated releases."
