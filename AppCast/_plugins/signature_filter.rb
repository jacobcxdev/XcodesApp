require "base64"
require "json"

module Jekyll
  module SignatureFilter
    TAG_PATTERN = /\Av[0-9]+\.[0-9]+\.[0-9]+b(?:0|[1-9][0-9]*)\z/

    def sparkle_signature(_release_body, release_tag = nil)
      unless TAG_PATTERN.match?(release_tag.to_s)
        raise Jekyll::Errors::FatalException, "Release tag is absent from the validated signature map."
      end

      path = ENV.fetch("VALIDATED_RELEASE_SIGNATURES_FILE", "")
      unless File.file?(path) && !File.symlink?(path)
        raise Jekyll::Errors::FatalException, "Validated release signature map is unavailable."
      end

      signatures = JSON.parse(File.read(path))
      unless signatures.is_a?(Hash) && signatures.all? { |tag, signature| TAG_PATTERN.match?(tag) && canonical_signature?(signature) }
        raise Jekyll::Errors::FatalException, "Validated release signature map is invalid."
      end

      signatures.fetch(release_tag) do
        raise Jekyll::Errors::FatalException, "Release tag is absent from the validated signature map."
      end
    rescue JSON::ParserError, SystemCallError
      raise Jekyll::Errors::FatalException, "Validated release signature map is invalid."
    end

    def canonical_signature?(signature)
      return false unless signature.is_a?(String)

      decoded = Base64.strict_decode64(signature)
      decoded.bytesize == 64 && Base64.strict_encode64(decoded) == signature
    rescue ArgumentError
      false
    end

    def escape_cdata(value)
      value.to_s.gsub("]]>", "]]]]><![CDATA[>")
    end
  end
end

Liquid::Template.register_filter(Jekyll::SignatureFilter)
