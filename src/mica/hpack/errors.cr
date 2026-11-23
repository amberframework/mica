module Mica::HPACK
  # Raised when a header block breaks RFC 7541: an index outside the
  # tables, an integer that overflows, a bad Huffman string, a table size
  # update in the wrong place or over the advertised size, or a block that
  # ends inside a field. `byte_offset` is the 0-based byte of the block
  # where the problem was found.
  #
  # The decoder's table no longer matches its peer's after this error, so
  # HTTP/2 treats it as a connection error of type COMPRESSION_ERROR
  # (RFC 9113, section 4.3), and the decoder refuses further blocks.
  class DecodingError < Mica::ParseError
  end

  # Raised when the block ends inside a field: an integer, a string or a
  # representation's first octet.
  class TruncatedBlockError < DecodingError
  end

  # Raised for an integer with more than `MAX_CONTINUATION_OCTETS`
  # continuation octets or a value over `MAX_INTEGER`.
  class IntegerOverflowError < DecodingError
  end

  # Raised for a Huffman string that contains the EOS symbol, ends with
  # more than 7 bits of padding, or pads with anything but 1 bits (RFC 7541,
  # section 5.2).
  class HuffmanError < DecodingError
  end

  # Raised for index 0, or an index past the end of the dynamic table.
  class InvalidIndexError < DecodingError
  end

  # Raised for a dynamic table size update that is over the advertised
  # maximum, that follows a field, or that is missing where a lowered
  # maximum requires one (RFC 7541, section 4.2).
  class TableSizeError < DecodingError
  end

  # Raised when a decode would pass one of its `DecodeLimits`. `limit`
  # names it: "max_header_list_bytes" or "max_header_block_bytes". The work
  # budget raises `Mica::WorkBudgetExceededError`.
  #
  # The decoder decodes the rest of a block whose header list passes
  # `max_header_list_bytes` (keeping its table in step with the peer's) but
  # keeps none of the fields past the limit, and raises once the block is
  # done. Its table is then intact (`table_intact?` is true), so the error
  # can stay a stream error (HTTP 431). After a `max_header_block_bytes`
  # error the block was not read, and the decoder refuses further blocks.
  class DecodeLimitError < Mica::LimitExceededError
    # The name of the limit, for example "max_header_list_bytes".
    getter limit : String

    def initialize(detail : String, position : Core::Position, @limit : String, @table_intact : Bool)
      super(detail, position)
    end

    # Returns true when the decoder's table still matches the peer's, so
    # later blocks can be decoded.
    def table_intact? : Bool
      @table_intact
    end
  end
end
