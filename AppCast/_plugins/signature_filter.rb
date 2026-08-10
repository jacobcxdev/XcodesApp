require "base64"

module Jekyll
  module SignatureFilter
    SIGNATURE_MARKER = "sparkle:edSignature="
    SIGNATURE_COMMENT = /\A[\t ]*<!-- sparkle:edSignature=(?<signature>[A-Za-z0-9+\/]+={0,2}) -->[\t ]*(?:\r?\n)?\z/

    def sparkle_signature(release_body)
      candidate_lines = release_body.to_s.lines.select { |line| line.include?(SIGNATURE_MARKER) }
      signature_match = SIGNATURE_COMMENT.match(candidate_lines.first.to_s)

      unless candidate_lines.one? && signature_match
        raise Jekyll::Errors::FatalException,
              "Release must contain exactly one standalone Sparkle Ed25519 signature comment."
      end

      signature = signature_match[:signature]
      decoded_signature = Base64.strict_decode64(signature)
      unless decoded_signature.bytesize == 64 && Base64.strict_encode64(decoded_signature) == signature
        raise Jekyll::Errors::FatalException,
              "Sparkle Ed25519 signature must be canonical Base64 encoding of exactly 64 bytes."
      end

      signature
    rescue ArgumentError
      raise Jekyll::Errors::FatalException,
            "Sparkle Ed25519 signature must use strict Base64 encoding."
    end

    def escape_cdata(value)
      value.to_s.gsub("]]>", "]]]]><![CDATA[>")
    end
  end
end

Liquid::Template.register_filter(Jekyll::SignatureFilter)
