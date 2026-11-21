require "./core"

# DEFLATE decoding in pure Crystal (RFC 1951), the format inside zlib
# (`Mica::Zlib`, RFC 1950) and gzip (`Mica::Gzip`, RFC 1952) streams. No
# libz.
#
# Every decode takes required `limits:` (`DecodeLimits`: output, ratio,
# window, members, metadata and work) and a required `timeout:` (a
# `Time::Span`, or nil for none), and raises a typed error before the
# output a limit guards is produced, so a decompression bomb costs bounded
# memory and time.
#
# ```
# limits = Mica::Deflate::DecodeLimits::REQUEST_BODY
# Mica::Gzip.decode(body, limits: limits, timeout: 2.seconds)
# ```
module Mica::Deflate
  # Decodes the raw DEFLATE stream *input* in one call. The stream must
  # end with its final block and nothing may follow it.
  def self.decode(input : Bytes, *, limits : DecodeLimits, timeout : Time::Span?) : Bytes
    Inflater.new(input, Format::Raw, limits, timeout).decode_all
  end
end

require "./deflate/errors"
require "./deflate/decode_limits"
require "./deflate/checksum"
require "./deflate/huffman_table"
require "./deflate/inflater"
require "./deflate/stream_reader"
require "./zlib"
require "./gzip"
