require "./deflate"

# zlib streams (RFC 1950): a two-byte header, DEFLATE data and an Adler-32
# of the output. The decoder checks the header (FCHECK, compression
# method 8, CINFO at most 7 and within `max_window_bytes`), a preset
# dictionary's id when FDICT is set, and the Adler-32.
#
# ```
# Mica::Zlib.decode(bytes, limits: Mica::Deflate::DecodeLimits::REQUEST_BODY, timeout: nil)
# ```
module Mica::Zlib
  # Decodes the zlib stream *input* in one call. *dictionary* is the
  # preset dictionary a stream with FDICT needs (its Adler-32 must match
  # the stream's DICTID). Nothing may follow the Adler-32.
  def self.decode(input : Bytes, *, limits : Deflate::DecodeLimits, timeout : Time::Span?,
                  dictionary : Bytes? = nil) : Bytes
    Deflate::Inflater.decode(input, Deflate::Format::Zlib, limits, timeout, dictionary)
  end

  # Decodes a zlib stream as it is read.
  class Reader < Deflate::StreamReader
    def initialize(io : IO, *, limits : Deflate::DecodeLimits, timeout : Time::Span?, dictionary : Bytes? = nil,
                   sync_close : Bool = false)
      super(io, Deflate::Format::Zlib, limits, timeout, dictionary, sync_close)
    end
  end
end
