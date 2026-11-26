module Mica::Brotli
  # The decoding engine behind `Mica::Brotli.decode` and
  # `Mica::Brotli::Reader` (RFC 7932).
  #
  # Input is pulled: when the decoder needs bits it takes them from its
  # source (a `Bytes` in place, or an `IO` through a buffer of up to
  # 64 KiB). Output goes into a ring buffer that is also the history back
  # references read. The ring starts as large as the first metablock needs
  # and doubles up to the stream's window (`1 << WBITS`); it is never
  # larger than the window, nor than `max_output_bytes` rounded up to a
  # power of two. The only place decoding pauses is a full ring, which the
  # caller drains (`pending`, `take`) before the decoder wraps around.
  #
  # Decoding stops every `RUN_BYTES` of output to settle the work meter,
  # the ratio check and the deadline. The output limit is checked
  # byte-exactly: when the next byte would pass `max_output_bytes` the
  # decode raises `DecodeLimitError` and the byte is never written.
  #
  # WARNING: A decoder belongs to one fiber at a time.
  #
  # :nodoc:
  class Decoder
    RUN_BYTES         = 65_536
    INPUT_BUFFER      = 65_536
    INITIAL_RING      =  4_096
    LITERAL_CODES     =    256
    COMMAND_CODES     =    704
    BLOCK_COUNT_CODES =     26
    # Bytes allocated past the ring's logical end, so a copy may move whole
    # 8-byte words.
    SLACK = 32
    # Bytes of slack after the transformed-word buffer (uppercasing may
    # touch two bytes past a word, RFC 7932, section 8).
    WORD_BUFFER = 64
    # The largest streaming ring a released decoder keeps for the next
    # stream (the window of `DecodeLimits::REQUEST_BODY`).
    KEPT_RING_BYTES = (4 << 20) + SLACK

    # Order of the code length code lengths (RFC 7932, section 3.5).
    CODE_LENGTH_ORDER = StaticArray[1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15]
    # The fixed code for code length code lengths, indexed by the next
    # four bits: how many bits the code takes and the length it means.
    CODE_LENGTH_PREFIX_BITS  = StaticArray[2, 2, 2, 3, 2, 2, 2, 4, 2, 2, 2, 3, 2, 2, 2, 4]
    CODE_LENGTH_PREFIX_VALUE = StaticArray[0, 4, 3, 2, 0, 4, 3, 1, 0, 4, 3, 2, 0, 4, 3, 5]

    # Block count codes (RFC 7932, section 6): base and extra bits.
    BLOCK_LENGTH_BASE = StaticArray[
      1, 5, 9, 13, 17, 25, 33, 41, 49, 65, 81, 97, 113, 145, 177, 209, 241, 305, 369, 497,
      753, 1265, 2289, 4337, 8433, 16625,
    ]
    BLOCK_LENGTH_EXTRA = StaticArray[
      2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 7, 8, 9, 10, 11, 12, 13, 24,
    ]

    # Insert and copy length codes (RFC 7932, section 5).
    INSERT_BASE = StaticArray[
      0, 1, 2, 3, 4, 5, 6, 8, 10, 14, 18, 26, 34, 50, 66, 98, 130, 194, 322, 578, 1090, 2114, 6210, 22594,
    ]
    INSERT_EXTRA = StaticArray[0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 12, 14, 24]
    COPY_BASE    = StaticArray[
      2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 14, 18, 22, 30, 38, 54, 70, 102, 134, 198, 326, 582, 1094, 2118,
    ]
    COPY_EXTRA = StaticArray[0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 24]
    # Each insert-and-copy symbol unpacked (RFC 7932, section 5): bits 0-15
    # hold the insert length base, 16-23 its extra bit count, 24-39 the
    # copy length base, 40-47 its extra bit count and 48-49 the distance
    # context (RFC 7932, section 7.2; copy lengths 2 to 4 have no extra
    # bits, so the code alone decides it).
    COMMAND_LUT = {% begin %}
      {% insert_base = [0, 1, 2, 3, 4, 5, 6, 8, 10, 14, 18, 26, 34, 50, 66, 98, 130, 194, 322, 578, 1090, 2114, 6210, 22594] %}
      {% insert_extra = [0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 12, 14, 24] %}
      {% copy_base = [2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 14, 18, 22, 30, 38, 54, 70, 102, 134, 198, 326, 582, 1094, 2118] %}
      {% copy_extra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 24] %}
      {% cell_insert = [0, 0, 0, 0, 8, 8, 0, 16, 8, 16, 16] %}
      {% cell_copy = [0, 8, 0, 8, 0, 8, 16, 0, 16, 8, 16] %}
      StaticArray[
        {% for symbol in 0...704 %}
          {% insert_code = cell_insert[symbol // 64] + (symbol // 8) % 8 %}
          {% copy_code = cell_copy[symbol // 64] + symbol % 8 %}
          {{ 1_i64 * insert_base[insert_code] + 65_536_i64 * insert_extra[insert_code] + 16_777_216_i64 * copy_base[copy_code] + 1_099_511_627_776_i64 * copy_extra[copy_code] + 281_474_976_710_656_i64 * (copy_code < 3 ? copy_code : 3) }},
        {% end %}
      ]
    {% end %}

    # The transforms' prefixes and suffixes as whole words for
    # `write_plain_word`: 16 bytes per transform ID, the prefix (at most
    # 5 bytes) in the first 8 and the suffix (at most 8) in the last 8,
    # zero padded.
    PLAIN_AFFIXES = begin
      affixes = Bytes.new(Tables::TRANSFORMS.size * 16)
      Tables::TRANSFORMS.each_with_index do |transform, id|
        affixes[id * 16, transform.prefix.size].copy_from(transform.prefix)
        affixes[id * 16 + 8, transform.suffix.size].copy_from(transform.suffix)
      end
      affixes
    end

    # BIT_MASK[n] keeps the low n bits (n from 0 to 64). Masks come from
    # this table, one load, rather than from a variable shift: without
    # BMI2 (baseline x86-64) a shift-built mask takes four instructions.
    BIT_MASK = {% begin %}
      StaticArray[
        {% for n in 0..64 %}
          {% digits = ["", "1", "3", "7"][n % 4] %}
          {% for _ in 0...(n // 4) %}{% digits = digits + "f" %}{% end %}
          {{ (n == 0 ? "0" : "0x" + digits).id }}_u64,
        {% end %}
      ]
    {% end %}

    # Short distance codes 0 to 15 (RFC 7932, section 4): which of the
    # last four distances, and the change to it.
    SHORT_DISTANCE_INDEX = StaticArray[0, 1, 2, 3, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1]
    SHORT_DISTANCE_DELTA = StaticArray[0, 0, 0, 0, -1, 1, -2, 2, -3, 3, -1, 1, -2, 2, -3, 3]

    private enum Phase
      StreamHeader
      MetablockHeader
      Uncompressed
      Commands
      Done
      Ended
    end

    private enum Stage
      # Read the next insert-and-copy command.
      Command
      # Insert `@insert_left` literals.
      Insert
      # Read the distance (or finish the metablock).
      Distance
      # Copy `@copy_left` bytes from `@copy_distance` back.
      Copy
      # Write `@word_left` bytes of the transformed word.
      Word
    end

    getter produced : Int64 = 0_i64

    @limits : DecodeLimits
    @meter : Core::WorkMeter

    # Input.
    @io : IO?
    @input : Bytes
    @in_pos : Int32 = 0
    @in_end : Int32 = 0
    @in_base : Int64 = 0_i64
    @consumed_total : Int64 = 0_i64
    @bits : UInt64 = 0_u64
    @bit_count : Int32 = 0

    # Output ring.
    @ring : Bytes = Bytes.empty
    @ring_size : Int32 = 0
    @ring_cap : Int32 = 0
    @full_ring : Int32 = 0
    @wrapped : Bool = false
    @pos : Int32 = 0
    @flushed : Int32 = 0
    @out_end : Int32 = 0
    @ring_base : Int64 = 0_i64
    @settled : Int64 = 0_i64
    @max_backward : Int32 = 0

    # Stream and metablock state.
    @phase : Phase = Phase::StreamHeader
    @stage : Stage = Stage::Command
    @is_last : Bool = false
    @meta_remaining : Int32 = 0
    @metadata_total : Int64 = 0_i64

    # Block switching, per category (0 literals, 1 commands, 2 distances).
    @num_types = StaticArray(Int32, 3).new(1)
    @block_left = StaticArray(Int32, 3).new(0)
    @block_type = StaticArray(Int32, 3).new(0)
    @type_ring = StaticArray(Int32, 6).new(0)
    @type_tree = StaticArray(Int32, 3).new(0)
    @length_tree = StaticArray(Int32, 3).new(0)

    @postfix_bits : Int32 = 0
    @postfix_mask : Int32 = 0
    @direct_codes : Int32 = 0
    # Per distance code from 16 on, for the current metablock's
    # postfix bits and direct codes: the distance with zero extra bits
    # in the low 32 bits and the extra bit count in the high 32
    # (RFC 7932, section 4). Then a distance is that base plus the extra
    # bits shifted left by the postfix bits.
    @distance_lut = Slice(Int64).new(16 + 120 + (48 << 3))
    @context_modes : Bytes = Bytes.new(256)
    @literal_map : Bytes = Bytes.new(64 * 256)
    @distance_map : Bytes = Bytes.new(4 * 256)
    @literal_trees = [] of Int32
    # Per literal tree: whether its codes are at most 14 bits long.
    @literal_tree_short = [] of Bool
    @command_trees = [] of Int32
    @distance_trees = [] of Int32
    @table = PrefixCode::Store.new
    # The current code's per-length symbol lists (see `PrefixCode::HEADS`)
    # and each list's last node.
    @code_lists = Slice(UInt16).new(COMMAND_CODES + PrefixCode::HEADS)
    @code_tails = StaticArray(UInt16, 16).new(0_u16)
    # The number of symbols with nonzero lengths, and the count per length.
    @code_used : Int32 = 0
    @code_count = StaticArray(Int32, 16).new(0)
    @lengths = Bytes.new(COMMAND_CODES)
    @mtf = Bytes.new(256)

    # The current literal block's context lookup and map rows.
    @context_lookup_offset : Int32 = 0
    @literal_map_offset : Int32 = 0
    @distance_map_offset : Int32 = 0
    @command_tree : Int32 = 0

    # The command being executed.
    @insert_left : Int32 = 0
    @copy_length : Int32 = 0
    @copy_left : Int32 = 0
    @copy_distance : Int32 = 0
    @implicit_distance : Bool = false
    @distances : StaticArray(Int32, 4) = StaticArray[4, 11, 15, 16]
    @word = Bytes.new(WORD_BUFFER)
    @word_at : Int32 = 0
    @word_left : Int32 = 0

    # The decoder the last decode released, ready for the next one.
    @@spare = Atomic(Decoder?).new(nil)

    # Whether output goes into one growing buffer that is never wrapped
    # (one-shot decoding) rather than a ring that is drained.
    @linear : Bool = false
    # The streaming input buffer, kept between decodes.
    @input_buffer : Bytes?
    # The streaming output ring, kept between decodes when it is at most
    # `KEPT_RING_BYTES`. A one-shot decode hands its ring to the caller,
    # so it never keeps one.
    @kept_ring : Bytes = Bytes.empty
    # The tree of the current literal block when its context map row names
    # one tree, else -1.
    @literal_tree_fixed : Int32 = -1
    # Per literal block type: the tree its whole context map row names, or
    # -1 when the row names more than one (worked out once per header).
    @fixed_tree_by_type = StaticArray(Int32, 256).new(-1)
    # Per literal block type with a fixed tree: whether that tree's codes
    # are at most 14 bits long (four fit in the 56 bits a refill leaves).
    @fixed_short_by_type = StaticArray(Bool, 256).new(false)
    @literal_tree_fixed_short : Bool = false
    # The context maps resolved to table offsets: per literal block type
    # and context, and per distance block type and context, the start of
    # the tree that context selects (one load fewer per symbol).
    @literal_tree_map = Slice(Int32).new(64)
    @distance_tree_map = Slice(Int32).new(4 * 256)

    def initialize(@limits : DecodeLimits)
      @meter = Core::WorkMeter.new(@limits.work_budget(nil))
      @input = Bytes.empty
    end

    # Returns a decoder ready for a new stream: the spare one, or a new one.
    def self.acquire(io : IO?, input : Bytes?, limits : DecodeLimits, timeout : Time::Span?) : Decoder
      decoder = @@spare.swap(nil) || new(limits)
      decoder.reset(io, input, limits, timeout)
      decoder
    end

    # Hands the decoder back for reuse; it keeps its tables and its input
    # buffer, and drops its source, its input and its output.
    def release : Nil
      @io = nil
      @input = Bytes.empty
      @kept_ring = @ring if !@linear && @ring.size <= KEPT_RING_BYTES && @ring.size > @kept_ring.size
      @ring = Bytes.empty
      @ring_size = 0
      @@spare.set(self)
    end

    # Starts a new stream.
    def reset(@io : IO?, input : Bytes?, @limits : DecodeLimits, timeout : Time::Span?) : Nil
      @meter.restart(@limits.work_budget(timeout))
      @in_pos = 0
      @in_base = 0_i64
      @bits = 0_u64
      @bit_count = 0
      if input
        @input = input
        @in_end = input.size
        @meter.add_units(input.size)
        @consumed_total = input.size.to_i64
      else
        @input = @input_buffer ||= Bytes.new(INPUT_BUFFER)
        @in_end = 0
        @consumed_total = 0_i64
      end
      @linear = io.nil?
      @produced = 0_i64
      @ring = @linear ? Bytes.empty : @kept_ring
      @ring_size = 0
      @ring_cap = 0
      @full_ring = 0
      @wrapped = false
      @pos = 0
      @flushed = 0
      @out_end = 0
      @ring_base = 0_i64
      @settled = 0_i64
      @max_backward = 0
      @phase = Phase::StreamHeader
      @stage = Stage::Command
      @is_last = false
      @meta_remaining = 0
      @metadata_total = 0_i64
      @distances = StaticArray[4, 11, 15, 16]
      @insert_left = 0
      @copy_left = 0
      @word_left = 0
    end

    # Decodes *input* in one call.
    def self.decode(input : Bytes, limits : DecodeLimits, timeout : Time::Span?) : Bytes
      decoder = acquire(nil, input, limits, timeout)
      begin
        while decoder.produce
        end
        decoder.linear_result
      ensure
        decoder.release
      end
    end

    # The whole output of a one-shot decode: the output buffer itself when
    # it is at most `2 * SLACK` bytes larger, an exact copy otherwise.
    protected def linear_result : Bytes
      return Bytes.empty if @pos == 0
      return @ring[0, @pos] if @ring.size - @pos <= 2 * SLACK
      @ring[0, @pos].dup
    end

    # Decoded bytes waiting to be taken.
    def pending : Bytes
      @ring[@flushed, @pos - @flushed]
    end

    # Marks *count* pending bytes as taken.
    def take(count : Int32) : Nil
      @flushed += count
    end

    # Decodes until the ring is full, a streaming run of `RUN_BYTES` is
    # pending, or the stream ends. Returns false once the stream has ended
    # and every byte is pending or taken.
    def produce : Bool
      return false if @phase.ended?
      if @pos == @ring_size && @ring_size == @full_ring && @flushed == @pos
        # The ring is full and drained: wrap around.
        @ring_base += @ring_size
        @pos = 0
        @flushed = 0
        @wrapped = true
        update_out_end
      end
      loop do
        case @phase
        in .stream_header?    then read_stream_header
        in .metablock_header? then read_metablock_header
        in .uncompressed?
          return true unless copy_uncompressed
        in .commands?
          return true unless run_commands
        in .done?
          finish_stream
          @phase = Phase::Ended
          return false
        in .ended?
          return false
        end
      end
    end

    # --- Input ----------------------------------------------------------

    private def position : Core::Position
      Core::Position.new(@in_base + @in_pos - (@bit_count >> 3))
    end

    private def malformed(message : String) : NoReturn
      raise MalformedStreamError.new(message, position)
    end

    private def truncated : NoReturn
      raise TruncatedStreamError.new("Input ends inside the Brotli stream", position)
    end

    private def limit_error(message : String, limit : String) : NoReturn
      raise DecodeLimitError.new(message, position, limit)
    end

    # Reads more input into the buffer; returns false at the end.
    private def fill_input : Bool
      io = @io
      return false unless io
      @in_base += @in_end
      @in_pos = 0
      count = io.read(@input)
      @in_end = count
      return false if count == 0
      @consumed_total += count
      @meter.add_units(count)
      @meter.enforce_deadline { position }
      true
    end

    # Fills the bit buffer to at least 57 bits, or to the end of input.
    @[AlwaysInline]
    private def refill : Nil
      if @in_end - @in_pos >= 8
        word = (@input.to_unsafe + @in_pos).as(UInt64*).value
        @bits |= word.unsafe_shl(@bit_count)
        @in_pos &+= (@bit_count >> 3) ^ 7
        @bit_count |= 56
        return
      end
      while @bit_count <= 56
        if @in_pos < @in_end
          @bits |= @input.unsafe_fetch(@in_pos).to_u64.unsafe_shl(@bit_count)
          @in_pos += 1
          @bit_count += 8
        else
          break unless fill_input
        end
      end
    end

    @[AlwaysInline]
    private def read_bits(count : Int32) : Int32
      return 0 if count == 0
      if @bit_count < count
        refill
        truncated if @bit_count < count
      end
      value = (@bits & BIT_MASK.unsafe_fetch(count)).to_i32!
      @bits = @bits.unsafe_shr(count)
      @bit_count &-= count
      value
    end

    # Reads one symbol of the code whose table starts at *tree*.
    @[AlwaysInline]
    private def read_symbol(tree : Int32) : Int32
      refill if @bit_count < 15
      table = @table.to_unsafe
      entry = table[tree + (@bits & 0xFF).to_i32]
      width = (entry & 0xFF).to_i32
      if width > PrefixCode::ROOT_BITS
        sub_width = width - PrefixCode::ROOT_BITS
        index = ((@bits >> PrefixCode::ROOT_BITS) & BIT_MASK.unsafe_fetch(sub_width)).to_i32!
        entry = table[tree + (entry >> 8).to_i32 + index]
        width = (entry & 0xFF).to_i32 + PrefixCode::ROOT_BITS
      end
      truncated if width > @bit_count
      @bits = @bits.unsafe_shr(width)
      @bit_count &-= width
      (entry >> 8).to_i32!
    end

    # Skips to the next byte boundary; the skipped bits must be zero.
    private def align_to_byte(what : String) : Nil
      skip = @bit_count & 7
      malformed("Nonzero padding bits #{what}") if read_bits(skip) != 0
    end

    # Reads one byte at a byte boundary.
    private def read_aligned_byte : UInt8
      read_bits(8).to_u8
    end

    # --- Headers --------------------------------------------------------

    private def read_stream_header : Nil
      window_bits =
        if read_bits(1) == 0
          16
        elsif (n = read_bits(3)) != 0
          17 + n
        else
          low_bits = read_bits(3)
          malformed("Large-window Brotli is not RFC 7932") if low_bits == 1
          low_bits == 0 ? 17 : 8 + low_bits
        end
      window = 1 << window_bits
      if window > @limits.max_window_bytes
        limit_error("The stream's window (#{window} bytes) exceeds max_window_bytes (#{@limits.max_window_bytes})",
          "max_window_bytes")
      end
      @full_ring = window
      @max_backward = window - 16
      cap = 1_024
      while cap < @limits.max_output_bytes && cap < window
        cap <<= 1
      end
      @ring_cap = cap
      if @linear
        # One growing buffer, never wrapped: as large as the output limit.
        limit = @limits.max_output_bytes
        @ring_cap = limit < Int32::MAX - 2 * SLACK ? limit.to_i32 : Int32::MAX - 2 * SLACK
        @full_ring = @ring_cap
      end
      @phase = Phase::MetablockHeader
    end

    private def read_metablock_header : Nil
      @is_last = read_bits(1) == 1
      if @is_last && read_bits(1) == 1
        @phase = Phase::Done
        return
      end
      nibbles = read_bits(2)
      if nibbles == 3
        malformed("Reserved bit set in a metadata metablock header") if read_bits(1) != 0
        skip_bytes = read_bits(2)
        skip = 0
        skip_bytes.times do |index|
          byte = read_bits(8)
          malformed("Exuberant metadata length byte") if index + 1 == skip_bytes && skip_bytes > 1 && byte == 0
          skip |= byte << (index * 8)
        end
        skip += 1 if skip_bytes > 0
        align_to_byte("after a metadata header")
        @metadata_total += skip
        if @metadata_total > @limits.max_metadata_bytes
          limit_error("Metadata exceeds max_metadata_bytes (#{@limits.max_metadata_bytes})", "max_metadata_bytes")
        end
        skip.times { read_aligned_byte }
        @meter.enforce { position } if @meter.charge(skip)
        @phase = Phase::Done if @is_last
        return
      end
      nibble_count = nibbles + 4
      length = 0
      nibble_count.times do |index|
        nibble = read_bits(4)
        malformed("Exuberant metablock length nibble") if index + 1 == nibble_count && nibble_count > 4 && nibble == 0
        length |= nibble << (index * 4)
      end
      @meta_remaining = length + 1
      uncompressed = !@is_last && read_bits(1) == 1
      ensure_ring(@meta_remaining)
      if uncompressed
        align_to_byte("before an uncompressed metablock")
        @phase = Phase::Uncompressed
        return
      end
      read_compressed_header
      @phase = Phase::Commands
      @stage = Stage::Command
    end

    # VarLenUint8 (RFC 7932, section 9.2), 0 to 255.
    private def read_var_len_uint8 : Int32
      return 0 if read_bits(1) == 0
      count = read_bits(3)
      return 1 if count == 0
      (1 << count) + read_bits(count)
    end

    private def read_compressed_header : Nil
      @table.clear
      3.times do |category|
        types = read_var_len_uint8 + 1
        @num_types[category] = types
        @block_type[category] = 0
        @type_ring[category * 2] = 1
        @type_ring[category * 2 + 1] = 0
        if types >= 2
          @type_tree[category] = read_prefix_code(types + 2, types + 2)
          @length_tree[category] = read_prefix_code(BLOCK_COUNT_CODES, BLOCK_COUNT_CODES)
          @block_left[category] = read_block_length(category)
        else
          @block_left[category] = Int32::MAX
        end
      end
      @postfix_bits = read_bits(2)
      @postfix_mask = (1 << @postfix_bits) - 1
      @direct_codes = read_bits(4) << @postfix_bits
      literal_types = @num_types[0]
      literal_types.times { |index| @context_modes[index] = read_bits(2).to_u8 }

      literal_trees = read_var_len_uint8 + 1
      read_context_map(@literal_map, 64 * literal_types, literal_trees)
      distance_trees = read_var_len_uint8 + 1
      read_context_map(@distance_map, 4 * @num_types[2], distance_trees)

      @literal_trees.clear
      @literal_tree_short.clear
      literal_trees.times do
        @literal_trees << read_prefix_code(LITERAL_CODES, LITERAL_CODES)
        @literal_tree_short << (@code_count[15] == 0)
      end
      @command_trees.clear
      @num_types[1].times { @command_trees << read_prefix_code(COMMAND_CODES, COMMAND_CODES) }
      distance_alphabet = 16 + @direct_codes + (48 << @postfix_bits)
      fill_distance_lut(distance_alphabet)
      @distance_trees.clear
      distance_trees.times { @distance_trees << read_prefix_code(distance_alphabet, distance_alphabet) }

      @meter.enforce { position } if @meter.charge(@table.size)
      map_literal_trees(literal_types)
      map_distance_trees(4 * @num_types[2])
      select_literal_block
      @command_tree = @command_trees.unsafe_fetch(0)
      @distance_map_offset = 0
    end

    private def read_block_length(category : Int32) : Int32
      code = read_symbol(@length_tree[category])
      BLOCK_LENGTH_BASE[code] + read_bits(BLOCK_LENGTH_EXTRA[code])
    end

    # Reads a prefix code over *alphabet* symbols and appends its table;
    # returns where the table starts.
    private def read_prefix_code(alphabet : Int32, limit : Int32) : Int32
      @code_used = 0
      @code_count = StaticArray(Int32, 16).new(0)
      @code_tails = StaticArray(UInt16, 16).new { |length| length.to_u16 }
      skip = read_bits(2)
      if skip == 1
        read_simple_code(alphabet, limit)
      else
        read_complex_code(alphabet, skip)
      end
      PrefixCode.build_from_lists(@code_lists, @code_used, @code_count, @table)
    end

    # Records that *symbol* has code *length* (nonzero); symbols arrive in
    # increasing order.
    @[AlwaysInline]
    private def add_code_symbol(symbol : Int32, length : Int32) : Nil
      @lengths[symbol] = length.to_u8
      node = PrefixCode.node(symbol)
      @code_lists[@code_tails[length]] = node
      @code_tails[length] = node
      @code_used += 1
      @code_count[length] += 1
    end

    private def read_simple_code(alphabet : Int32, limit : Int32) : Nil
      count = read_bits(2) + 1
      symbol_bits = 0
      while (1 << symbol_bits) < alphabet
        symbol_bits += 1
      end
      symbols = StaticArray(Int32, 4).new(0)
      count.times do |index|
        symbol = read_bits(symbol_bits)
        malformed("Simple prefix code symbol #{symbol} is outside the alphabet") if symbol >= limit
        symbols[index] = symbol
      end
      count.times do |left|
        (left + 1...count).each do |right|
          malformed("Simple prefix code repeats a symbol") if symbols[left] == symbols[right]
        end
      end
      widths = StaticArray(Int32, 4).new(0)
      case count
      when 1
        widths[0] = 1
      when 2
        widths[0] = 1
        widths[1] = 1
      when 3
        widths[0] = 1
        widths[1] = 2
        widths[2] = 2
      else
        if read_bits(1) == 0
          4.times { |index| widths[index] = 2 }
        else
          widths[0] = 1
          widths[1] = 2
          widths[2] = 3
          widths[3] = 3
        end
      end
      # Listed in increasing symbol order.
      order = StaticArray[0, 1, 2, 3]
      (1...count).each do |index|
        at = index
        while at > 0 && symbols[order[at - 1]] > symbols[order[at]]
          order[at - 1], order[at] = order[at], order[at - 1]
          at -= 1
        end
      end
      count.times { |index| add_code_symbol(symbols[order[index]], widths[order[index]]) }
    end

    private def read_complex_code(alphabet : Int32, skip : Int32) : Nil
      code_lengths = StaticArray(UInt8, 18).new(0_u8)
      space = 32
      used = 0
      (skip...18).each do |index|
        refill if @bit_count < 4
        peek = (@bits & 0xF).to_i32
        width = CODE_LENGTH_PREFIX_BITS[peek]
        read_bits(width)
        value = CODE_LENGTH_PREFIX_VALUE[peek]
        code_lengths[CODE_LENGTH_ORDER[index]] = value.to_u8
        next if value == 0
        space -= 32 >> value
        used += 1
        break if space <= 0
      end
      malformed("Code length code is not complete") unless used == 1 || space == 0

      # The code length code is at most 5 bits long: a 32-entry table of
      # (symbol << 3 | length), on the stack.
      code_table = StaticArray(UInt16, 32).new(0_u16)
      if used == 1
        single = (0...18).find { |index| code_lengths[index] != 0 } || 0
        32.times { |index| code_table[index] = (single << 3).to_u16 }
      else
        per_length = StaticArray(Int32, 6).new(0)
        code_lengths.each { |length| per_length[length] += 1 }
        # The first canonical code of each length.
        next_code = StaticArray(Int32, 6).new(0)
        code = 0
        (1..5).each do |length|
          next_code[length] = code
          code = (code + per_length[length]) << 1
        end
        18.times do |symbol|
          length = code_lengths[symbol].to_i32
          next if length == 0
          index = PrefixCode.reverse(next_code[length], length)
          next_code[length] += 1
          entry = ((symbol << 3) | length).to_u16
          while index < 32
            code_table[index] = entry
            index += 1 << length
          end
        end
      end

      symbol = 0
      previous = 8
      repeat = 0
      repeat_length = 0
      space = 32_768
      # The symbol lists' tails and per-length counts in locals for the loop
      # (`add_code_symbol` inlined); stored back at the end.
      used_symbols = @code_used
      length_count = @code_count
      tails = @code_tails
      lengths_out = @lengths.to_unsafe
      lists_out = @code_lists.to_unsafe
      # The bit buffer and input position live in locals while at least
      # 16 input bytes remain (a code length symbol and its extra bits take
      # at most 8 bits); near the end the careful readers take over.
      input = @input.to_unsafe
      bits = @bits
      nbits = @bit_count
      in_pos = @in_pos
      in_limit = @in_end - 16
      while symbol < alphabet && space > 0
        careful = in_pos > in_limit
        code = 0
        extra = 0
        if careful
          @bits = bits
          @bit_count = nbits
          @in_pos = in_pos
          refill if @bit_count < 5
          entry = code_table[(@bits & 31).to_i32!]
          width = (entry & 7).to_i32
          truncated if width > @bit_count
          @bits >>= width
          @bit_count -= width
          code = (entry >> 3).to_i32
          extra = read_bits(code == 16 ? 2 : 3) if code >= 16
          input = @input.to_unsafe
          bits = @bits
          nbits = @bit_count
          in_pos = @in_pos
          in_limit = @in_end - 16
        else
          fast_refill if nbits < 8
          entry = code_table[(bits & 31).to_i32!]
          width = (entry & 7).to_i32!
          bits >>= width
          nbits &-= width
          code = (entry >> 3).to_i32!
          if code >= 16
            width = code == 16 ? 2 : 3
            extra = (bits & ((1_u64 << width) &- 1)).to_i32!
            bits >>= width
            nbits &-= width
          end
        end
        if code < 16
          repeat = 0
          if code != 0
            lengths_out[symbol] = code.to_u8!
            node = PrefixCode.node(symbol)
            lists_out[tails.unsafe_fetch(code)] = node
            tails.unsafe_put(code, node)
            used_symbols &+= 1
            length_count[code] &+= 1
            previous = code
            space -= 32_768 >> code
          end
          symbol += 1
          next
        end
        extra_bits = code == 16 ? 2 : 3
        new_length = code == 16 ? previous : 0
        if repeat_length != new_length
          repeat = 0
          repeat_length = new_length
        end
        old_repeat = repeat
        if repeat > 0
          repeat -= 2
          repeat <<= extra_bits
        end
        repeat += extra + 3
        delta = repeat - old_repeat
        if symbol + delta > alphabet
          @bits = bits
          @bit_count = nbits
          @in_pos = in_pos
          malformed("Code length repeat runs past the alphabet")
        end
        if repeat_length != 0
          length_byte = repeat_length.to_u8!
          # The run's symbols join their length's list in order.
          lists_out[tails.unsafe_fetch(repeat_length)] = PrefixCode.node(symbol)
          delta.times do |index|
            lengths_out[symbol &+ index] = length_byte
            lists_out[PrefixCode.node(symbol &+ index)] = PrefixCode.node(symbol &+ index &+ 1)
          end
          tails.unsafe_put(repeat_length, PrefixCode.node(symbol &+ delta &- 1))
          used_symbols &+= delta
          length_count[repeat_length] &+= delta
        end
        symbol += delta
        space -= delta << (15 - repeat_length) if repeat_length != 0
      end
      @bits = bits
      @bit_count = nbits
      @in_pos = in_pos
      @code_used = used_symbols
      @code_count = length_count
      @code_tails = tails
      malformed("Prefix code is not complete") if space != 0
    end

    private def read_context_map(map : Bytes, size : Int32, trees : Int32) : Nil
      if trees < 2
        map[0, size].fill(0_u8)
        return
      end
      run_length_max = read_bits(1) == 1 ? read_bits(4) + 1 : 0
      tree = read_prefix_code(trees + run_length_max, trees + run_length_max)
      index = 0
      while index < size
        code = read_symbol(tree)
        if code == 0
          map[index] = 0_u8
          index += 1
        elsif code <= run_length_max
          run = (1 << code) + read_bits(code)
          malformed("Context map run passes the map's end") if index + run > size
          map[index, run].fill(0_u8)
          index += run
        else
          map[index] = (code - run_length_max).to_u8
          index += 1
        end
      end
      inverse_move_to_front(map, size) if read_bits(1) == 1
      @meter.enforce { position } if @meter.charge(size)
    end

    private def inverse_move_to_front(map : Bytes, size : Int32) : Nil
      mtf = @mtf.to_unsafe
      # The identity permutation, eight bytes per store.
      word = 0x0706050403020100_u64
      32.times do |index|
        (mtf + (index << 3)).as(UInt64*).value = word
        word &+= 0x0808080808080808_u64
      end
      entries = map.to_unsafe
      size.times do |index|
        position = entries[index].to_i32!
        value = mtf[position]
        entries[index] = value
        while position > 0
          mtf[position] = mtf[position &- 1]
          position &-= 1
        end
        mtf[0] = value
      end
    end

    # --- Block switching ------------------------------------------------

    private def switch_block(category : Int32) : Nil
      code = read_symbol(@type_tree[category])
      types = @num_types[category]
      ring = category * 2
      block_type =
        case code
        when 0 then @type_ring[ring]
        when 1 then @type_ring[ring + 1] + 1
        else        code - 2
        end
      block_type -= types if block_type >= types
      @type_ring[ring] = @type_ring[ring + 1]
      @type_ring[ring + 1] = block_type
      @block_type[category] = block_type
      @block_left[category] = read_block_length(category)
    end

    private def select_literal_block : Nil
      block_type = @block_type[0]
      @context_lookup_offset = @context_modes[block_type].to_i32 << 9
      @literal_map_offset = block_type << 6
      @literal_tree_fixed = @fixed_tree_by_type.unsafe_fetch(block_type)
      @literal_tree_fixed_short = @fixed_short_by_type.unsafe_fetch(block_type)
    end

    # Fills `@literal_tree_map` and `@fixed_tree_by_type` for the *types*
    # literal block types: a row of 64 equal context map entries (compared
    # as eight 8-byte words) always selects the same tree.
    private def map_literal_trees(types : Int32) : Nil
      @literal_tree_map = Slice(Int32).new(64 * types) if @literal_tree_map.size < 64 * types
      map = @literal_map.to_unsafe
      trees = @literal_trees.to_unsafe
      tree_map = @literal_tree_map.to_unsafe
      (64 * types).times { |index| tree_map[index] = trees[map[index]] }
      types.times do |block_type|
        row = map + (block_type << 6)
        pattern = row[0].to_u64 &* 0x0101010101010101_u64
        same = true
        8.times do |word|
          same = false unless (row + (word << 3)).as(UInt64*).value == pattern
        end
        @fixed_tree_by_type[block_type] = same ? @literal_trees.unsafe_fetch(row[0].to_i32) : -1
        @fixed_short_by_type[block_type] = same && @literal_tree_short.unsafe_fetch(row[0].to_i32)
      end
    end

    # Fills `@distance_tree_map` for the first *size* context map entries.
    private def map_distance_trees(size : Int32) : Nil
      map = @distance_map.to_unsafe
      trees = @distance_trees.to_unsafe
      tree_map = @distance_tree_map.to_unsafe
      size.times { |index| tree_map[index] = trees[map[index]] }
    end

    # --- Output ---------------------------------------------------------

    # Makes the ring large enough for *count* more bytes, up to the
    # window (and the output cap).
    private def ensure_ring(count : Int32) : Nil
      return if @ring_size == @full_ring || @ring_size == @ring_cap
      want = @pos.to_i64 + count
      return if want <= @ring_size
      if @is_last
        # The last metablock's length is the rest of the output.
        size = want < @ring_cap ? want.to_i32 : @ring_cap
      else
        size = Math.max(@ring_size, INITIAL_RING).to_i64
        while size < want && size < @ring_cap
          size <<= 1
        end
        size = @ring_cap.to_i64 if size > @ring_cap
        size = size.to_i32
      end
      grow_ring(size) if size > @ring_size
    end

    # Makes the ring *size* bytes long. A kept ring that is large enough
    # grows in place; otherwise the bytes so far move to a new buffer.
    # The new buffer is not zeroed: a copy only reads bytes the stream
    # has written (a distance never reaches past the output so far).
    private def grow_ring(size : Int32) : Nil
      if @ring.size < size + SLACK
        ring = Bytes.new(GC.malloc_atomic(LibC::SizeT.new(size + SLACK)).as(UInt8*), size + SLACK)
        ring.copy_from(@ring.to_unsafe, @pos) if @pos > 0
        @ring = ring
      end
      @ring_size = size
      update_out_end
    end

    private def update_out_end : Nil
      total = @ring_base + @pos
      room = @limits.max_output_bytes - total
      stop = @ring_size.to_i64
      stop = @pos.to_i64 + RUN_BYTES if @pos.to_i64 + RUN_BYTES < stop
      stop = @pos.to_i64 + room if @pos.to_i64 + room < stop
      @out_end = stop.to_i32
    end

    # Called when the next byte would land at `@out_end`. Returns false
    # when the caller must stop for the ring to be drained: it is full, or
    # (streaming) a run is pending.
    private def make_room : Bool
      settle
      total = @ring_base + @pos
      if total >= @limits.max_output_bytes
        limit_error("Output exceeds max_output_bytes (#{@limits.max_output_bytes})", "max_output_bytes")
      end
      if @pos == @ring_size
        return false if @ring_size == @full_ring || @ring_size == @ring_cap
        doubled = @ring_size.to_i64 << 1
        grow_ring(doubled < @ring_cap ? doubled.to_i32 : @ring_cap)
      end
      update_out_end
      # A streaming decode stops at each run with output pending, so the
      # caller takes that run while it is still in cache.
      @linear || @pos == @flushed
    end

    # Settles the work meter, the ratio check and the deadline for the
    # output produced since the last settlement.
    private def settle : Nil
      total = @ring_base + @pos
      @produced = total
      fresh = total - @settled
      @settled = total
      return if fresh <= 0
      @meter.add_units(fresh)
      @meter.enforce { position } if @meter.charge(fresh)
      if total > DecodeLimits::RATIO_GRACE_BYTES
        consumed = @consumed_total - (@in_end - @in_pos) - (@bit_count >> 3)
        consumed = 1_i64 if consumed < 1
        if total > consumed * @limits.max_ratio
          limit_error("Output exceeds max_ratio (#{@limits.max_ratio}:1)", "max_ratio")
        end
      end
    end

    # --- Uncompressed metablocks ----------------------------------------

    private def copy_uncompressed : Bool
      while @meta_remaining > 0
        if @pos == @out_end
          return false unless make_room
        end
        if @bit_count >= 8
          @ring[@pos] = read_aligned_byte
          @pos += 1
          @meta_remaining -= 1
          next
        end
        # The bit buffer is empty: drop the bits a wide refill loaded past
        # its count, then copy from the input directly.
        @bits = 0_u64
        if @in_pos == @in_end
          truncated unless fill_input
        end
        count = Math.min(@meta_remaining, Math.min(@out_end - @pos, @in_end - @in_pos))
        (@ring.to_unsafe + @pos).copy_from(@input.to_unsafe + @in_pos, count)
        @pos += count
        @in_pos += count
        @meta_remaining -= count
      end
      @phase = Phase::MetablockHeader
      true
    end

    # --- Commands -------------------------------------------------------

    private def run_commands : Bool
      loop do
        case @stage
        in .command?
          if @meta_remaining == 0
            finish_metablock
            return true
          end
          fast_commands if @in_end - @in_pos > FAST_INPUT_MARGIN
          next unless @stage.command?
          if @meta_remaining == 0
            finish_metablock
            return true
          end
          read_command
        in .insert?
          return false unless insert_literals
          @stage = Stage::Distance
        in .distance?
          if @meta_remaining == 0
            finish_metablock
            @stage = Stage::Command
            return true
          end
          read_distance
        in .copy?
          return false unless copy_match
          @stage = Stage::Command
        in .word?
          return false unless write_word
          @stage = Stage::Command
        end
      end
    end

    # The fast loop starts a command, or a literal run or block switch
    # inside one, only while more than this many input bytes remain, so
    # its refills can load 8 bytes without checking the end. Past such a
    # check a command reads at most 210 bits (a command block switch, 54;
    # the command symbol and both length extras, 63; a distance block
    # switch, 54; the distance symbol and its extra bits, 39), and a
    # literal run stops at the check's position plus one literal; with
    # at most 63 bits buffered and 8-byte loads, the last load ends at
    # most 43 bytes past the check.
    FAST_INPUT_MARGIN = 64

    # Refills the local bit buffer of `fast_commands` from 8 input bytes.
    private macro fast_refill
      %word = (input + in_pos).as(UInt64*).value
      bits |= %word.unsafe_shl(nbits)
      in_pos &+= (nbits >> 3) ^ 7
      nbits |= 56
    end

    # Reads one symbol in `fast_commands` (at least 15 bits are buffered).
    private macro fast_symbol(tree, into)
      %entry = table[{{tree}} &+ (bits & 0xFF).to_i32!]
      %width = (%entry & 0xFF).to_i32!
      if %width > PrefixCode::ROOT_BITS
        %sub = %width &- PrefixCode::ROOT_BITS
        %entry = table[{{tree}} &+ (%entry >> 8).to_i32! &+ ((bits >> PrefixCode::ROOT_BITS) & BIT_MASK.unsafe_fetch(%sub)).to_i32!]
        %width = (%entry & 0xFF).to_i32! &+ PrefixCode::ROOT_BITS
      end
      bits = bits.unsafe_shr(%width)
      nbits &-= %width
      {{into}} = (%entry >> 8).to_i32!
    end

    # Reads *count* (at most 24) bits in `fast_commands`.
    private macro fast_bits(count, into)
      fast_refill if nbits < {{count}}
      {{into}} = (bits & BIT_MASK.unsafe_fetch({{count}})).to_i32!
      bits = bits.unsafe_shr({{count}})
      nbits &-= {{count}}
    end

    # Switches the block type of *category* in `fast_commands` (RFC 7932,
    # section 6): reads the block type code and the block count.
    private macro fast_switch(category)
      fast_refill
      %code = 0
      fast_symbol(@type_tree[{{category}}], %code)
      %types = @num_types[{{category}}]
      %block_type =
        case %code
        when 0 then @type_ring[{{category}} * 2]
        when 1 then @type_ring[{{category}} * 2 + 1] &+ 1
        else        %code &- 2
        end
      %block_type &-= %types if %block_type >= %types
      @type_ring[{{category}} * 2] = @type_ring[{{category}} * 2 + 1]
      @type_ring[{{category}} * 2 + 1] = %block_type
      @block_type[{{category}}] = %block_type
      fast_refill
      %length_code = 0
      fast_symbol(@length_tree[{{category}}], %length_code)
      %extra = 0
      %width = BLOCK_LENGTH_EXTRA[%length_code]
      fast_bits(%width, %extra)
      @block_left[{{category}}] = BLOCK_LENGTH_BASE[%length_code] &+ %extra
    end

    private macro fast_save
      @bits = bits
      @bit_count = nbits
      @in_pos = in_pos
      @pos = pos
      @block_left[1] = command_left
      @block_left[2] = distance_left
      @distances = last_distances
      @meta_remaining = meta_end &- pos
      @copy_length = copy_length
      @implicit_distance = implicit
      @command_tree = command_tree
    end

    private macro fast_load
      bits = @bits
      nbits = @bit_count
      in_pos = @in_pos
      pos = @pos
      table = @table.to_unsafe
      ring = @ring.to_unsafe
      command_left = @block_left[1]
      distance_left = @block_left[2]
      last_distances = @distances
      meta_end = pos &+ @meta_remaining
      command_tree = @command_tree
      stop = meta_end < @out_end ? meta_end : @out_end
    end

    # Executes whole commands with the bit buffer, the input position and
    # the output position in locals, while at least `FAST_INPUT_MARGIN`
    # input bytes remain and each command's output fits before
    # `@out_end`. Anything else (block switches, dictionary words, a
    # command that would cross `@out_end`, copies whose source wraps) is
    # left to the careful path through `@stage`.
    private def fast_commands : Nil
      input = @input.to_unsafe
      in_limit = @in_end - FAST_INPUT_MARGIN
      lookup = Tables::CONTEXT_LOOKUP.to_unsafe
      bits = 0_u64
      nbits = 0
      in_pos = 0
      pos = 0
      # The command and distance block counts and the last four distances
      # live in locals: as instance variables every store to them had to be
      # repeated in memory, since a ring write might alias them.
      command_left = 0
      distance_left = 0
      last_distances = @distances
      # Likewise the metablock's end as an output position, the command
      # being run, and where output must stop: the metablock's end or
      # `@out_end`, whichever comes first.
      meta_end = 0
      copy_length = 0
      implicit = false
      command_tree = 0
      stop = 0
      table = @table.to_unsafe
      ring = @ring.to_unsafe
      # The metablock's distance parameters and the ring's history, fixed
      # while this runs, in locals: a ring store may alias any field.
      postfix_bits = @postfix_bits
      distance_lut = @distance_lut.to_unsafe
      distance_tree_map = @distance_tree_map.to_unsafe
      written_before = @ring_base
      max_backward = @max_backward
      fast_load
      while pos < meta_end && in_pos <= in_limit
        if command_left == 0
          fast_switch(1)
          command_left = @block_left[1]
          command_tree = @command_trees.unsafe_fetch(@block_type[1])
        end
        command_left &-= 1
        fast_refill if nbits < 15
        symbol = 0
        fast_symbol(command_tree, symbol)
        # A command symbol is below COMMAND_CODES (704). Both lengths'
        # extra bits (at most 48) are read at once.
        command = COMMAND_LUT.unsafe_fetch(symbol)
        insert_width = (command >> 16).to_i32! & 0xFF
        both_width = insert_width &+ ((command >> 40).to_i32! & 0xFF)
        fast_refill if nbits < both_width
        length_bits = bits & BIT_MASK.unsafe_fetch(both_width)
        bits = bits.unsafe_shr(both_width)
        nbits &-= both_width
        insert = (command.to_i32! & 0xFFFF) &+ (length_bits & BIT_MASK.unsafe_fetch(insert_width)).to_i32!
        copy_length = ((command >> 24).to_i32! & 0xFFFF) &+ length_bits.unsafe_shr(insert_width).to_i32!
        extra = 0
        implicit = symbol < 128
        if pos &+ insert > stop
          fast_save
          malformed("Insert length runs past the metablock") if insert > @meta_remaining
          @insert_left = insert
          @stage = Stage::Insert
          return
        end
        if insert > 0
          left = insert
          # The literal block's state in locals for the loop.
          block_left = @block_left[0]
          fixed_tree = @literal_tree_fixed
          fixed_short = @literal_tree_fixed_short
          lookup_row = lookup + @context_lookup_offset
          tree_row = @literal_tree_map.to_unsafe + @literal_map_offset
          while left > 0
            if in_pos > in_limit
              fast_save
              @block_left[0] = block_left
              @insert_left = left
              @stage = Stage::Insert
              return
            end
            if block_left == 0
              fast_switch(0)
              select_literal_block
              block_left = @block_left[0]
              fixed_tree = @literal_tree_fixed
              fixed_short = @literal_tree_fixed_short
              lookup_row = lookup + @context_lookup_offset
              tree_row = @literal_tree_map.to_unsafe + @literal_map_offset
              next
            end
            # A run of literals inside one block that the input margin
            # covers (a literal takes at most 15 bits, so two bytes),
            # decoded without per-literal block or input checks.
            run = left < block_left ? left : block_left
            room = (in_limit &- in_pos) >> 1
            run = room if room < run
            run = 1 if run < 1
            block_left &-= run
            left &-= run
            if fixed_tree >= 0
              # One tree for the whole block: no context. A refill leaves
              # at least 56 bits: four literals of at most 14 bits, or
              # three of at most 15.
              if fixed_short
                while run >= 4
                  fast_refill
                  literal = 0
                  fast_symbol(fixed_tree, literal)
                  ring[pos] = literal.to_u8!
                  fast_symbol(fixed_tree, literal)
                  ring[pos &+ 1] = literal.to_u8!
                  fast_symbol(fixed_tree, literal)
                  ring[pos &+ 2] = literal.to_u8!
                  fast_symbol(fixed_tree, literal)
                  ring[pos &+ 3] = literal.to_u8!
                  pos &+= 4
                  run &-= 4
                end
              end
              while run >= 3
                fast_refill
                literal = 0
                fast_symbol(fixed_tree, literal)
                ring[pos] = literal.to_u8!
                fast_symbol(fixed_tree, literal)
                ring[pos &+ 1] = literal.to_u8!
                fast_symbol(fixed_tree, literal)
                ring[pos &+ 2] = literal.to_u8!
                pos &+= 3
                run &-= 3
              end
              while run > 0
                fast_refill if nbits < 15
                literal = 0
                fast_symbol(fixed_tree, literal)
                ring[pos] = literal.to_u8!
                pos &+= 1
                run &-= 1
              end
              next
            end
            # The context comes from the last two bytes written.
            if pos >= 2
              p1 = ring[pos &- 1].to_i32!
              p2 = ring[pos &- 2].to_i32!
            else
              fast_save
              p1, p2 = last_two_bytes
            end
            while run > 0
              tree = tree_row[lookup_row[p1] | lookup_row[256 &+ p2]]
              fast_refill if nbits < 15
              literal = 0
              fast_symbol(tree, literal)
              ring[pos] = literal.to_u8!
              pos &+= 1
              p2 = p1
              p1 = literal
              run &-= 1
            end
          end
          @block_left[0] = block_left
        end
        if pos == meta_end
          fast_save
          @stage = Stage::Command
          return
        end

        code = 0
        distance = last_distances[0]
        unless implicit
          if distance_left == 0
            fast_switch(2)
            distance_left = @block_left[2]
            @distance_map_offset = @block_type[2] << 2
          end
          distance_left &-= 1
          tree = distance_tree_map[@distance_map_offset &+ (command >> 48).to_i32!]
          fast_refill if nbits < 15
          fast_symbol(tree, code)
          if code < 16
            distance = last_distances.unsafe_fetch(SHORT_DISTANCE_INDEX.unsafe_fetch(code)) &+ SHORT_DISTANCE_DELTA.unsafe_fetch(code)
            if distance <= 0
              fast_save
              malformed("Distance code #{code} gives a distance below 1")
            end
          else
            # At most 24 extra bits (none for a direct code); the
            # distance stays inside 32 bits.
            entry = distance_lut[code]
            width = (entry >> 32).to_i32!
            fast_bits(width, extra)
            distance = entry.to_i32! &+ extra.unsafe_shl(postfix_bits)
          end
        end
        # The output so far, capped at the window's reach.
        max_distance = written_before &+ pos < max_backward ? (written_before &+ pos).to_i32! : max_backward
        if distance > max_distance
          fast_save
          start_dictionary_word(distance, max_distance)
          return unless @stage.command?
          fast_load
          next
        end
        if code != 0
          last_distances = StaticArray[distance, last_distances[0], last_distances[1], last_distances[2]]
        end
        source = pos &- distance
        if source < 0 || pos &+ copy_length > stop
          fast_save
          malformed("Copy length runs past the metablock") if copy_length > @meta_remaining
          @copy_left = copy_length
          @copy_distance = distance
          @stage = Stage::Copy
          return
        end
        # Whole words: up to 15 bytes past the copy land in the slack or
        # in the 16 oldest bytes of history, which no back reference can
        # reach (the longest distance is the window less 16).
        destination = ring + pos
        origin = ring + source
        if distance >= 16
          # A copy is at least 2 bytes: the first 16 always move.
          (destination.as(UInt64*)).value = origin.as(UInt64*).value
          (destination + 8).as(UInt64*).value = (origin + 8).as(UInt64*).value
          at = 16
          while at < copy_length
            low_word = (origin + at).as(UInt64*).value
            high_word = (origin + (at &+ 8)).as(UInt64*).value
            (destination + at).as(UInt64*).value = low_word
            (destination + (at &+ 8)).as(UInt64*).value = high_word
            at &+= 16
          end
        elsif distance >= 8
          at = 0
          while at < copy_length
            (destination + at).as(UInt64*).value = (origin + at).as(UInt64*).value
            at &+= 8
          end
        elsif distance == 1
          # A run of one byte.
          Slice.new(destination, copy_length).fill(origin.value)
        else
          # A short repeating pattern: byte by byte until the copied part
          # holds the pattern at a period of 8 or more, then whole words
          # from that period back.
          period = distance
          while period < 8
            period &+= distance
          end
          head = period &- distance
          head = copy_length if head > copy_length
          at = 0
          while at < head
            destination[at] = origin[at]
            at &+= 1
          end
          while at < copy_length
            (destination + at).as(UInt64*).value = (destination + (at &- period)).as(UInt64*).value
            at &+= 8
          end
        end
        pos &+= copy_length
      end
      fast_save
      @stage = Stage::Command
    end

    private def read_command : Nil
      if @block_left[1] == 0
        switch_block(1)
        @command_tree = @command_trees.unsafe_fetch(@block_type[1])
      end
      @block_left[1] -= 1
      symbol = read_symbol(@command_tree)
      command = COMMAND_LUT[symbol]
      @implicit_distance = symbol < 128
      @insert_left = (command.to_i32! & 0xFFFF) + read_bits((command >> 16).to_i32! & 0xFF)
      @copy_length = ((command >> 24).to_i32! & 0xFFFF) + read_bits((command >> 40).to_i32! & 0xFF)
      malformed("Insert length runs past the metablock") if @insert_left > @meta_remaining
      @stage = Stage::Insert
    end

    private def insert_literals : Bool
      return true if @insert_left == 0
      p1, p2 = last_two_bytes
      ring = @ring.to_unsafe
      lookup = Tables::CONTEXT_LOOKUP.to_unsafe
      while @insert_left > 0
        if @pos == @out_end
          return false unless make_room
          ring = @ring.to_unsafe
        end
        if @block_left[0] == 0
          switch_block(0)
          select_literal_block
        end
        @block_left[0] -= 1
        tree = @literal_tree_fixed
        if tree < 0
          context = lookup[@context_lookup_offset + p1] | lookup[@context_lookup_offset + 256 + p2]
          tree = @literal_tree_map.unsafe_fetch(@literal_map_offset + context)
        end
        literal = read_symbol(tree)
        ring[@pos] = literal.to_u8
        @pos += 1
        p2 = p1
        p1 = literal
        @insert_left -= 1
        @meta_remaining -= 1
      end
      true
    end

    # The last two bytes written (0 before the stream has two).
    private def last_two_bytes : {Int32, Int32}
      total = @ring_base + @pos
      last = @pos - 1
      last += @ring_size if last < 0
      before = last - 1
      before += @ring_size if before < 0
      p1 = total >= 1 ? @ring[last].to_i32 : 0
      p2 = total >= 2 ? @ring[before].to_i32 : 0
      {p1, p2}
    end

    private def read_distance : Nil
      code = 0
      distance =
        if @implicit_distance
          @distances[0]
        else
          if @block_left[2] == 0
            switch_block(2)
            @distance_map_offset = @block_type[2] << 2
          end
          @block_left[2] -= 1
          context = @copy_length > 4 ? 3 : @copy_length - 2
          tree = @distance_tree_map.unsafe_fetch(@distance_map_offset + context)
          code = read_symbol(tree)
          translate_distance(code)
        end
      total = @ring_base + @pos
      max_distance = total < @max_backward ? total.to_i32 : @max_backward
      if distance > max_distance
        start_dictionary_word(distance, max_distance)
        return
      end
      if code != 0
        @distances[3] = @distances[2]
        @distances[2] = @distances[1]
        @distances[1] = @distances[0]
        @distances[0] = distance
      end
      malformed("Copy length runs past the metablock") if @copy_length > @meta_remaining
      @copy_left = @copy_length
      @copy_distance = distance
      @stage = Stage::Copy
    end

    # Fills `@distance_lut` for codes 16 to *alphabet* - 1.
    private def fill_distance_lut(alphabet : Int32) : Nil
      lut = @distance_lut.to_unsafe
      (16...alphabet).each do |code|
        if code < 16 + @direct_codes
          lut[code] = (code - 15).to_i64
          next
        end
        offset_code = code - @direct_codes - 16
        extra_bits = 1 + (offset_code >> (@postfix_bits + 1))
        high = offset_code >> @postfix_bits
        low = offset_code & @postfix_mask
        offset = ((2 + (high & 1)) << extra_bits) - 4
        lut[code] = ((offset << @postfix_bits) + low + @direct_codes + 1).to_i64 | (extra_bits.to_i64 << 32)
      end
    end

    private def translate_distance(code : Int32) : Int32
      if code < 16
        distance = @distances[SHORT_DISTANCE_INDEX[code]] + SHORT_DISTANCE_DELTA[code]
        malformed("Distance code #{code} gives a distance below 1") if distance <= 0
        return distance
      end
      entry = @distance_lut.unsafe_fetch(code)
      entry.to_i32! + (read_bits((entry >> 32).to_i32!) << @postfix_bits)
    end

    private def start_dictionary_word(distance : Int32, max_distance : Int32) : Nil
      length = @copy_length
      unless Dictionary::MIN_WORD_LENGTH <= length <= Dictionary::MAX_WORD_LENGTH
        malformed("Distance #{distance} is beyond the window and the copy length #{length} is not a dictionary word length")
      end
      word_id = distance - max_distance - 1
      size_bits = Dictionary::SIZE_BITS_BY_LENGTH[length].to_i32
      word_index = word_id & ((1 << size_bits) - 1)
      transform_id = word_id >> size_bits
      malformed("Dictionary transform #{transform_id} does not exist") if transform_id >= Tables::TRANSFORMS.size
      offset = Dictionary::OFFSETS_BY_LENGTH[length] + word_index * length
      transform = Tables::TRANSFORMS.unsafe_fetch(transform_id)
      return if write_plain_word(transform, transform_id, offset, length)
      size = apply_transform(transform, Dictionary::DATA.to_unsafe + offset, length)
      malformed("Dictionary word runs past the metablock") if size > @meta_remaining
      if @pos + size <= @out_end
        # Room before the next stop: write the word straight out, in whole
        # 8-byte words (the ring has slack past its end).
        source = @word.to_unsafe
        destination = @ring.to_unsafe + @pos
        at = 0
        while at < size
          (destination + at).as(UInt64*).value = (source + at).as(UInt64*).value
          at &+= 8
        end
        @pos += size
        @meta_remaining -= size
        @stage = Stage::Command
        return
      end
      @word_left = size
      @word_at = 0
      @stage = Stage::Word
    end

    # Writes a dictionary word whose transform only adds a prefix and a
    # suffix (kind 0, the common case) straight into the ring, all in whole
    # 8-byte words, when it fits before `@out_end`. Returns false, writing
    # nothing, otherwise. The words reach at most 8 bytes past the
    # transformed word: into the ring's slack, or into the 16 oldest bytes
    # of history, which no back reference can reach.
    private def write_plain_word(transform : Tables::Transform, transform_id : Int32, offset : Int32, length : Int32) : Bool
      return false unless transform.kind == 0
      prefix = transform.prefix
      suffix = transform.suffix
      size = prefix.size &+ length &+ suffix.size
      malformed("Dictionary word runs past the metablock") if size > @meta_remaining
      return false if @pos &+ size > @out_end
      data = Dictionary::DATA
      # The 8-byte reads stay inside the dictionary.
      return false if offset &+ length &+ 8 > data.size
      destination = @ring.to_unsafe + @pos
      affixes = PLAIN_AFFIXES.to_unsafe + (transform_id << 4)
      # The prefix word; the word below overwrites its padding (a
      # dictionary word is at least 4 bytes, copied as at least 8).
      destination.as(UInt64*).value = affixes.as(UInt64*).value
      destination += prefix.size
      source = data.to_unsafe + offset
      at = 0
      while at < length
        (destination + at).as(UInt64*).value = (source + at).as(UInt64*).value
        at &+= 8
      end
      destination += length
      (destination.as(UInt64*)).value = (affixes + 8).as(UInt64*).value
      @pos &+= size
      @meta_remaining &-= size
      @stage = Stage::Command
      true
    end

    # Writes the transformed *word* into `@word`; returns its length.
    private def apply_transform(transform : Tables::Transform, word : UInt8*, length : Int32) : Int32
      buffer = @word.to_unsafe
      prefix = transform.prefix
      size = 0
      while size < prefix.size
        buffer[size] = prefix.unsafe_fetch(size)
        size &+= 1
      end
      kind = transform.kind.to_i32
      start = 0
      if 1 <= kind <= 9
        length = Math.max(length - kind, 0)
      elsif kind >= 12
        start = Math.min(kind - 11, length)
        length -= start
      end
      word_start = size
      index = 0
      while index < length
        buffer[size &+ index] = word[start &+ index]
        index &+= 1
      end
      size &+= length
      # Uppercasing may touch up to two bytes past the word; those bytes
      # are then overwritten by the suffix or ignored.
      buffer[size] = 0_u8
      buffer[size + 1] = 0_u8
      if kind == 10
        uppercase(buffer, word_start) if length > 0
      elsif kind == 11
        at = word_start
        left = length
        while left > 0
          step = uppercase(buffer, at)
          at += step
          left -= step
        end
      end
      suffix = transform.suffix
      index = 0
      while index < suffix.size
        buffer[size &+ index] = suffix.unsafe_fetch(index)
        index &+= 1
      end
      size &+ suffix.size
    end

    # RFC 7932, section 8: uppercases the character at *at*; returns its
    # length in this simplified UTF-8 model.
    private def uppercase(buffer : UInt8*, at : Int32) : Int32
      byte = buffer[at]
      if byte < 0xC0
        buffer[at] = byte ^ 32 if 'a'.ord <= byte <= 'z'.ord
        return 1
      end
      if byte < 0xE0
        buffer[at + 1] ^= 32
        return 2
      end
      buffer[at + 2] ^= 5
      3
    end

    private def write_word : Bool
      while @word_left > 0
        if @pos == @out_end
          return false unless make_room
        end
        count = Math.min(@word_left, @out_end - @pos)
        (@ring.to_unsafe + @pos).copy_from(@word.to_unsafe + @word_at, count)
        @pos += count
        @word_at += count
        @word_left -= count
        @meta_remaining -= count
      end
      true
    end

    private def copy_match : Bool
      distance = @copy_distance
      while @copy_left > 0
        if @pos == @out_end
          return false unless make_room
        end
        count = Math.min(@copy_left, @out_end - @pos)
        source = @pos - distance
        source += @ring_size if source < 0
        ring = @ring.to_unsafe
        if source + count <= @ring_size && (distance >= count || source > @pos)
          (ring + @pos).move_from(ring + source, count)
        else
          destination = @pos
          count.times do
            ring[destination] = ring[source]
            destination += 1
            source += 1
            source = 0 if source == @ring_size
          end
        end
        @pos += count
        @copy_left -= count
        @meta_remaining -= count
      end
      true
    end

    private def finish_metablock : Nil
      @phase = @is_last ? Phase::Done : Phase::MetablockHeader
    end

    # --- End of stream --------------------------------------------------

    private def finish_stream : Nil
      align_to_byte("after the last metablock")
      if @bit_count > 0 || @in_pos < @in_end || fill_input
        malformed("Data after the end of the Brotli stream")
      end
      settle
    end
  end
end
