require "./core"

# Brotli (RFC 7932) in pure Crystal: no libbrotlidec, no libbrotlienc.
#
# Every decode takes required `limits:` (`DecodeLimits`: output, ratio,
# window, metadata and work) and a required `timeout:` (a `Time::Span`, or
# nil for none), and raises a typed error before the output a limit
# guards is produced, so a decompression bomb costs bounded memory and
# time.
#
# ```
# limits = Mica::Brotli::DecodeLimits::REQUEST_BODY
# Mica::Brotli.decode(body, limits: limits, timeout: 2.seconds)
# ```
module Mica::Brotli
  # Decodes the Brotli stream *input* in one call. The stream must end
  # with its last metablock, zero padding bits, and nothing after it.
  def self.decode(input : Bytes, *, limits : DecodeLimits, timeout : Time::Span?) : Bytes
    Decoder.decode(input, limits, timeout)
  end
end

require "./brotli/errors"
require "./brotli/decode_limits"
require "./brotli/dictionary"
require "./brotli/tables"
require "./brotli/prefix_code"
require "./brotli/decoder"
require "./brotli/reader"
