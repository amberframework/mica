module Mica::HPACK
  # Upper bounds on what one `Decoder` may do with each header block. A
  # decoder takes them as a required `limits:` argument (there is no
  # default): use a preset (`PUBLIC_SERVER`, `INTERNAL_SERVER`, `CLIENT`) or
  # `DecodeLimits.custom`.
  #
  # The work allowance follows `Core::WorkBudget`, with one unit per block
  # byte:
  #
  #     allowance = min(base_work + work_per_unit * block_bytes, work_ceiling)
  #
  # Decoding charges one operation per block byte, two per Huffman-coded
  # byte and one per decoded byte, so the budget only stops blocks that
  # spend their bytes on table references.
  #
  # ```
  # limits = Mica::HPACK::DecodeLimits.custom(max_header_list_bytes: 65_536)
  # limits.max_table_bytes # => 4_096 (from PUBLIC_SERVER)
  # ```
  struct DecodeLimits
    # Decoded header list bytes per block, counted as RFC 9113 counts
    # SETTINGS_MAX_HEADER_LIST_SIZE: name and value bytes plus 32 per field.
    getter max_header_list_bytes : Int32
    # Encoded bytes per block (HEADERS or PUSH_PROMISE plus its
    # CONTINUATION frames).
    getter max_header_block_bytes : Int32
    # The largest SETTINGS_HEADER_TABLE_SIZE the decoder advertises, and so
    # the most memory its dynamic table may hold once the peer has
    # acknowledged it. Until then a peer may use the protocol default of
    # 4,096 bytes (RFC 9113, section 6.5.2), so the table holds at most
    # the larger of the two.
    getter max_table_bytes : Int32
    # Work operations allowed per block byte.
    getter work_per_unit : Int64
    # Work operations allowed per block regardless of size.
    getter base_work : Int64
    # An absolute cap on work operations per block, or nil for none.
    getter work_ceiling : Int64?

    def initialize(@max_header_list_bytes : Int32, @max_header_block_bytes : Int32, @max_table_bytes : Int32,
                   @work_per_unit : Int64, @base_work : Int64, @work_ceiling : Int64? = nil)
      raise ArgumentError.new("max_header_list_bytes must not be negative") if @max_header_list_bytes < 0
      raise ArgumentError.new("max_header_block_bytes must not be negative") if @max_header_block_bytes < 0
      raise ArgumentError.new("max_table_bytes must not be negative") if @max_table_bytes < 0
      raise ArgumentError.new("work_per_unit must not be negative") if @work_per_unit < 0
      raise ArgumentError.new("base_work must not be negative") if @base_work < 0
      if ceiling = @work_ceiling
        raise ArgumentError.new("work_ceiling must not be negative") if ceiling < 0
      end
    end

    # Returns limits that start from `PUBLIC_SERVER` and change only the
    # values given.
    def self.custom(*, max_header_list_bytes : Int32 = PUBLIC_SERVER.max_header_list_bytes,
                    max_header_block_bytes : Int32 = PUBLIC_SERVER.max_header_block_bytes,
                    max_table_bytes : Int32 = PUBLIC_SERVER.max_table_bytes,
                    work_per_unit : Int64 = PUBLIC_SERVER.work_per_unit,
                    base_work : Int64 = PUBLIC_SERVER.base_work,
                    work_ceiling : Int64? = PUBLIC_SERVER.work_ceiling) : self
      new(max_header_list_bytes, max_header_block_bytes, max_table_bytes, work_per_unit, base_work, work_ceiling)
    end

    # Returns the work budget these limits allow for one block.
    def work_budget : Core::WorkBudget
      Core::WorkBudget.new(operations_per_unit: @work_per_unit, base_operations: @base_work,
        max_operations: @work_ceiling)
    end

    # For a server that faces the internet: 16 KiB of decoded headers (the
    # stdlib HTTP/1.1 server's `MAX_HEADERS_SIZE`), 32 KiB of encoded block
    # and the protocol's default 4 KiB table.
    PUBLIC_SERVER = new(
      max_header_list_bytes: 16_384,
      max_header_block_bytes: 32_768,
      max_table_bytes: DEFAULT_TABLE_SIZE,
      work_per_unit: 64_i64,
      base_work: 100_000_i64,
    )

    # For a server behind a proxy the operator runs: 64 KiB of decoded
    # headers and 128 KiB of encoded block.
    INTERNAL_SERVER = new(
      max_header_list_bytes: 65_536,
      max_header_block_bytes: 131_072,
      max_table_bytes: DEFAULT_TABLE_SIZE,
      work_per_unit: 64_i64,
      base_work: 100_000_i64,
    )

    # For a client reading responses from servers it does not control:
    # 64 KiB of decoded headers and 128 KiB of encoded block.
    CLIENT = new(
      max_header_list_bytes: 65_536,
      max_header_block_bytes: 131_072,
      max_table_bytes: DEFAULT_TABLE_SIZE,
      work_per_unit: 64_i64,
      base_work: 100_000_i64,
    )
  end
end
