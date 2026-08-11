#!/usr/bin/env ruby

require "base64"

body_path = ARGV.fetch(0)
body = File.binread(body_path)
marker = "sparkle:edSignature="
comment = /\A[\t ]*<!-- sparkle:edSignature=(?<signature>[A-Za-z0-9+\/]+={0,2}) -->[\t ]*(?:\r?\n)?\z/
candidate_lines = body.lines.select { |line| line.include?(marker) }
match = comment.match(candidate_lines.first.to_s)
raise "Release body must contain exactly one standalone Sparkle Ed25519 signature comment" unless candidate_lines.one? && match

signature = match[:signature]
decoded = Base64.strict_decode64(signature)
unless decoded.bytesize == 64 && Base64.strict_encode64(decoded) == signature
  raise "Release body Sparkle signature must be canonical Base64 encoding of exactly 64 bytes"
end

puts signature
