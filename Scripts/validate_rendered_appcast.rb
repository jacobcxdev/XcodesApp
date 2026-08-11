#!/usr/bin/env ruby

require "rexml/document"
require "uri"

appcast_path, release_tag, signature_path = ARGV
match = /\Av(?<version>[0-9]+\.[0-9]+\.[0-9]+)b(?<build>0|[1-9][0-9]*)\z/.match(release_tag.to_s)
raise "Release tag must match vX.Y.ZbN exactly" unless match
signature = File.read(signature_path).strip
document = REXML::Document.new(File.read(appcast_path))
enclosures = REXML::XPath.match(document, "//enclosure").select do |enclosure|
  enclosure.attributes["sparkle:version"] == match[:build] &&
    enclosure.attributes["sparkle:shortVersionString"] == match[:version]
end
raise "Rendered stable appcast must contain the verified release exactly once" unless enclosures.one?

enclosure = enclosures.first
raise "Rendered appcast signature does not match verified release" unless enclosure.attributes["sparkle:edSignature"] == signature
url = URI.parse(enclosure.attributes["url"])
raise "Rendered appcast does not reference exact Xcodes.zip asset" unless File.basename(url.path) == "Xcodes.zip"

puts "Rendered appcast contains verified release #{release_tag}"
