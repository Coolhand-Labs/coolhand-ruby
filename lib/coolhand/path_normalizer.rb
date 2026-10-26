# frozen_string_literal: true

module Coolhand
  module PathNormalizer
    UNRESERVED_CHAR = /\A[A-Za-z0-9\-._~]\z/
    private_constant :UNRESERVED_CHAR

    module_function

    # Path used for matching only (the URL that is sent and logged is never touched), so
    # sloppy joins like "/openai//files", "/openai/./files", "/openai/%66iles" or
    # "/v2/chat/../../v1/rerank" can't slip past an exclude pattern or a path anchor.
    # Decodes unreserved-character escapes (%2F and other reserved escapes stay encoded, and
    # decoding is one pass, so "%252e" stays literal), collapses repeated "/", and resolves
    # "." and ".." segments without ever climbing above the root. Case is left as is. A path
    # that can't be normalized falls back to the raw one rather than raising, and an empty
    # path comes back as "/".
    def normalize(path)
      decoded = path.gsub(/%\h\h/) do |escape|
        char = escape[1, 2].hex.chr
        UNRESERVED_CHAR.match?(char) ? char : escape
      end
      segments = decoded.split("/").each_with_object([]) do |segment, kept|
        case segment
        when "", "." then next
        when ".." then kept.pop
        else kept << segment
        end
      end
      directory = !segments.empty? && decoded.end_with?("/", "/.", "/..")
      "/#{segments.join('/')}#{'/' if directory}"
    rescue StandardError
      path
    end
  end
end
