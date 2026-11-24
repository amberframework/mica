module Mica::HPACK
  # Decodes the header blocks one peer sends on one connection, in order,
  # keeping the dynamic table they share.
  #
  # ```
  # decoder = Mica::HPACK::Decoder.new(limits: Mica::HPACK::DecodeLimits::PUBLIC_SERVER)
  # decoder.decode(Bytes[0x82]) # => [Mica::HPACK::Header(@name=":method", @value="GET", @never_indexed=false)]
  # ```
  #
  # Any `DecodingError` leaves the table out of step with the peer's, and
  # the decoder then raises `DecodingError` for every later block.
  #
  # WARNING: A decoder is not concurrency-safe; one fiber owns it.
  class Decoder
    # The limits this decoder enforces.
    getter limits : DecodeLimits

    # The maximum table size the decoder has advertised and the peer has
    # acknowledged (SETTINGS_HEADER_TABLE_SIZE). It starts at the protocol
    # default, 4,096 bytes, which a peer may use until it acknowledges our
    # first SETTINGS frame.
    getter max_table_size : Int32

    @table : DynamicTable
    @meter : Core::WorkMeter
    @failed = false
    # Set when the advertised maximum dropped below the table's capacity:
    # the next block must start with a size update (RFC 7541, section 4.2).
    @size_update_required = false

    # *max_table_size* is the table size both sides start with: the
    # protocol default, or a size agreed before the first block.
    def initialize(*, @limits : DecodeLimits, max_table_size : Int32 = DEFAULT_TABLE_SIZE)
      unless 0 <= max_table_size <= Math.max(@limits.max_table_bytes, DEFAULT_TABLE_SIZE)
        raise ArgumentError.new("max_table_size must be between 0 and #{Math.max(@limits.max_table_bytes, DEFAULT_TABLE_SIZE)}")
      end
      @max_table_size = max_table_size
      @table = DynamicTable.new(@max_table_size)
      @meter = Core::WorkMeter.new(@limits.work_budget)
    end

    # Changes the advertised maximum table size, once the peer has
    # acknowledged the SETTINGS frame that carried it. Raises
    # `ArgumentError` for a size over `DecodeLimits#max_table_bytes`.
    def max_table_size=(size : Int32) : Int32
      unless 0 <= size <= @limits.max_table_bytes
        raise ArgumentError.new("max_table_size must be between 0 and #{@limits.max_table_bytes}")
      end
      @size_update_required = true if size < @table.capacity
      @max_table_size = size
    end

    # Returns the dynamic table's current maximum size, as the peer last
    # set it.
    def table_capacity : Int32
      @table.capacity
    end

    # Returns the bytes the dynamic table's entries take.
    def table_size : Int32
      @table.size
    end

    # Returns the number of entries in the dynamic table.
    def table_length : Int32
      @table.length
    end

    # Decodes *block* and returns its fields in order.
    def decode(block : Bytes) : Array(Header)
      list_of_headers = [] of Header
      decode(block) { |header| list_of_headers << header }
      list_of_headers
    end

    # Decodes *block* and yields its fields in order.
    def decode(block : Bytes, & : Header ->) : Nil
      if @failed
        raise DecodingError.new("The decoder failed on an earlier block", Core::Position.new(0_i64))
      end
      if block.size > @limits.max_header_block_bytes
        @failed = true
        raise DecodeLimitError.new("Header block of #{block.size} bytes is over max_header_block_bytes " \
                                   "(#{@limits.max_header_block_bytes})", Core::Position.new(0_i64),
          "max_header_block_bytes", false)
      end
      @meter.restart(@limits.work_budget)
      @meter.add_units(block.size)
      begin
        decode_fields(block) { |header| yield header }
      rescue error : DecodingError | WorkBudgetExceededError
        @failed = true
        raise error
      end
    end

    private def decode_fields(block : Bytes, & : Header ->) : Nil
      position = 0
      list_bytes = 0_i64
      over_list_at = -1
      at_block_start = true
      if @size_update_required && block.empty?
        raise TableSizeError.new("Expected a dynamic table size update", Core::Position.new(0_i64))
      end
      while position < block.size
        start = position
        first = block.to_unsafe[position]
        if first >= 0x80
          index, position = PrefixInteger.decode(block, position, 7)
          header = lookup(index, start)
          charge(position - start, start)
        elsif first >= 0x40
          header, position = read_literal(block, position, 6, start)
          @table.add(header)
        elsif first >= 0x20
          unless at_block_start
            raise TableSizeError.new("Dynamic table size update after a field", Core::Position.new(start.to_i64))
          end
          size, position = PrefixInteger.decode(block, position, 5)
          if size > @max_table_size
            raise TableSizeError.new("Dynamic table size update to #{size} is over the advertised maximum " \
                                     "#{@max_table_size}", Core::Position.new(start.to_i64))
          end
          @table.capacity = size.to_i32
          @size_update_required = false if size <= @max_table_size
          charge(position - start, start)
          next
        else
          header, position = read_literal(block, position, 4, start)
          header = header.copy_with(never_indexed: true) if first >= 0x10
        end
        if @size_update_required
          raise TableSizeError.new("Expected a dynamic table size update at the start of the block",
            Core::Position.new(start.to_i64))
        end
        at_block_start = false
        list_bytes += header.size
        if list_bytes > @limits.max_header_list_bytes
          over_list_at = start if over_list_at < 0
        else
          # Decoded bytes are charged as they are produced; references past
          # the list limit produce nothing.
          charge(header.size, start) if first >= 0x80
          yield header
        end
      end
      if @size_update_required
        raise TableSizeError.new("Expected a dynamic table size update", Core::Position.new(0_i64))
      end
      if over_list_at >= 0
        raise DecodeLimitError.new("Header list of #{list_bytes} bytes is over max_header_list_bytes " \
                                   "(#{@limits.max_header_list_bytes})", Core::Position.new(over_list_at.to_i64),
          "max_header_list_bytes", true)
      end
    end

    private def charge(count : Int32, offset : Int32) : Nil
      @meter.enforce { Core::Position.new(offset.to_i64) } if @meter.charge(count)
    end

    private def lookup(index : Int64, offset : Int32) : Header
      if index == 0
        raise InvalidIndexError.new("Index 0 is not a table entry", Core::Position.new(offset.to_i64))
      end
      return StaticTable[index.to_i32] if index <= StaticTable::SIZE
      entry = @table[(index - StaticTable::SIZE - 1).to_i32]? if index - StaticTable::SIZE <= Int32::MAX
      return entry if entry
      raise InvalidIndexError.new("Index #{index} is past the end of the tables (#{StaticTable::SIZE + @table.length} " \
                                  "entries)", Core::Position.new(offset.to_i64))
    end

    # Reads a literal field whose name index has a *prefix*-bit prefix.
    private def read_literal(block : Bytes, position : Int32, prefix : Int32, start : Int32) : {Header, Int32}
      index, position = PrefixInteger.decode(block, position, prefix)
      if index == 0
        name, position = read_string(block, position)
      else
        name = lookup(index, start).name
      end
      value, position = read_string(block, position)
      charge(position - start + name.bytesize + value.bytesize, start)
      {Header.new(name, value), position}
    end

    # Reads a string literal (RFC 7541, section 5.2).
    private def read_string(block : Bytes, position : Int32) : {String, Int32}
      if position >= block.size
        raise TruncatedBlockError.new("Header block ends before a string", Core::Position.new(position.to_i64))
      end
      huffman = block.to_unsafe[position] >= 0x80
      start = position
      length, position = PrefixInteger.decode(block, position, 7)
      if length > block.size - position
        raise TruncatedBlockError.new("String of #{length} bytes runs past the end of the header block",
          Core::Position.new(start.to_i64))
      end
      raw = block[position, length.to_i32]
      position += length.to_i32
      return {String.new(raw), position} unless huffman
      charge(raw.size * 2, start)
      capacity = raw.size * 8 // 5
      failed = false
      text = String.new(capacity) do |buffer|
        written = Huffman.decode(raw, buffer)
        failed = written < 0
        {failed ? 0 : written, 0}
      end
      if failed
        raise HuffmanError.new("Huffman string contains EOS or invalid padding", Core::Position.new(start.to_i64))
      end
      {text, position}
    end
  end
end
