require "./deflate"

# gzip streams (RFC 1952): one or more members, each a header, DEFLATE
# data, a CRC-32 and the size modulo 2^32. The decoder checks the magic
# bytes, compression method 8, the reserved flag bits, the header CRC
# (FHCRC), each member's CRC-32 and size, and `max_members` and
# `max_metadata_bytes`. After a member the input either ends or starts
# another member.
#
# ```
# Mica::Gzip.decode(bytes, limits: Mica::Deflate::DecodeLimits::REQUEST_BODY, timeout: nil)
# ```
module Mica::Gzip
  # One member's header fields. *file_name* and *comment* are the raw
  # bytes (RFC 1952 says ISO 8859-1) without the terminating zero.
  record Header, modification_time : UInt32, extra_flags : UInt8, operating_system : UInt8, is_text : Bool,
    extra_field : Bytes?, file_name : Bytes?, comment : Bytes?

  # Decodes the gzip stream *input* (every member) in one call.
  def self.decode(input : Bytes, *, limits : Deflate::DecodeLimits, timeout : Time::Span?) : Bytes
    Deflate::Inflater.decode(input, Deflate::Format::Gzip, limits, timeout)
  end

  # Decodes a gzip stream (every member) as it is read.
  class Reader < Deflate::StreamReader
    # The headers of the members read so far.
    getter list_of_headers = [] of Header

    def initialize(io : IO, *, limits : Deflate::DecodeLimits, timeout : Time::Span?, sync_close : Bool = false)
      super(io, Deflate::Format::Gzip, limits, timeout, nil, sync_close, @list_of_headers)
    end
  end
end
