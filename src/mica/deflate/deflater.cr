module Mica::Deflate
  # The encoding engine behind `Mica::Deflate`, `Mica::Zlib` and
  # `Mica::Gzip`, one-shot and streaming.
  #
  # It follows zlib's deflate algorithm (deflate.c) so that compressed
  # sizes track zlib's level for level: a 32 KiB history, hash chains over
  # 3-byte sequences with zlib's hash, zlib's per-level parameters (levels
  # 1 to 3 take the first good match, levels 4 to 9 look one byte ahead
  # for a better one before committing), and a buffer of up to 16,383
  # symbols that `BlockWriter` turns into the smallest of a stored, a
  # fixed-Huffman and a dynamic-Huffman block. Level 0 writes stored
  # blocks. Where Mica differs from zlib: a match may reach the full
  # 32,768 bytes back (zlib stops 262 bytes short).
  #
  # The input is addressed through one pointer:
  #
  # - one-shot: the caller's bytes are searched in place and nothing is
  #   copied;
  # - streaming (and any encode with a preset dictionary): bytes are
  #   copied into a window of `WINDOW_CAPACITY` bytes, and when it fills
  #   the last 32 KiB slide to its front.
  #
  # The hash table holds stream positions, so nothing in it changes when
  # the window slides, and the chain table holds each position's distance
  # to the previous position with the same hash. Candidates are compared
  # eight bytes at a time.
  #
  # Memory per stream at any level from 1 to 9: the window (66,560 bytes,
  # streaming only), the hash table (131,072), the chain table (65,536) and
  # the symbol buffer (65,536): 328,704 bytes, plus the output buffer.
  #
  # WARNING: A deflater belongs to one fiber at a time.
  #
  # :nodoc:
  class Deflater
    # The DEFLATE history.
    WINDOW      = 32_768
    WINDOW_MASK = WINDOW - 1
    # The shortest and longest match.
    MIN_MATCH =   3
    MAX_MATCH = 258
    # While at least this many bytes lie ahead, a match can run its full
    # length; the engine waits for more input below it unless it is
    # flushing.
    MIN_LOOKAHEAD = MAX_MATCH + MIN_MATCH + 1
    # zlib's hash: 15 bits over three bytes, each shifted 5 bits further.
    HASH_SIZE = 32_768
    HASH_MASK = (HASH_SIZE - 1).to_u32
    # A block is written when it holds this many symbols (zlib's symbol
    # buffer at its default memory level).
    SYMBOL_LIMIT = 16_383
    # A match of the minimum length this far back costs more than three
    # literals; zlib drops it.
    TOO_FAR = 4_096
    # The streaming window: the history plus the room new input is copied
    # into. One byte more than the history is kept on a slide so the byte
    # 32,768 back stays reachable.
    WINDOW_CAPACITY = 2 * WINDOW + 1_024
    WINDOW_KEEP     = WINDOW + 1
    # The streaming output buffer starts at this size and grows only when
    # one block needs more.
    STREAM_OUTPUT_BYTES = 16_384

    # zlib's parameters of one level (its `configuration_table`): stop
    # searching hard once a match is *good_length* long; do not look for a
    # better match past *max_lazy* (levels 1 to 3: the longest match whose
    # inner positions are still hashed); stop at a match of *nice_length*;
    # follow at most *max_chain* candidates.
    record LevelParameters, good_length : Int32, max_lazy : Int32, nice_length : Int32, max_chain : Int32,
      is_lazy : Bool

    LEVELS = StaticArray[
      LevelParameters.new(0, 0, 0, 0, false),
      LevelParameters.new(4, 4, 8, 4, false),
      LevelParameters.new(4, 5, 16, 8, false),
      LevelParameters.new(4, 6, 32, 32, false),
      LevelParameters.new(4, 4, 16, 16, true),
      LevelParameters.new(8, 16, 32, 32, true),
      LevelParameters.new(8, 16, 128, 128, true),
      LevelParameters.new(8, 32, 128, 256, true),
      LevelParameters.new(32, 128, 258, 1_024, true),
      LevelParameters.new(32, 258, 258, 4_096, true),
    ]

    # Raises `ArgumentError` unless *level* is 0 to 9.
    def self.check_level(level : Int32) : Nil
      raise ArgumentError.new("Invalid compression level #{level}: must be 0 to 9") unless 0 <= level <= 9
    end

    # Encodes *input* in one call and returns the stream.
    def self.encode(input : Bytes, format : Format, level : Int32, dictionary : Bytes? = nil,
                    header : Gzip::Header? = nil) : Bytes
      deflater = new(format, level, nil, dictionary, header, input.size)
      if dictionary
        deflater.write(input)
      else
        deflater.write_in_place(input)
      end
      deflater.finish
      deflater.result
    end

    @format : Format
    @level : Int32
    @parameters : LevelParameters
    @dictionary : Bytes?
    @header : Gzip::Header?
    @blocks : BlockWriter

    # The byte at offset `n` of the input the engine can still see is
    # `@source[n]`; `@base` is the stream position of offset 0.
    @source : UInt8* = Pointer(UInt8).null
    @base : UInt32 = 0_u32
    @window : Bytes?
    # The offset being encoded, the end of the input seen so far, and the
    # start of the block being collected.
    @position : Int32 = 0
    @fill : Int32 = 0
    @block_start : Int32 = 0
    # False once the window has slid past the start of the block being
    # collected: its bytes cannot be written as a stored block any more.
    @block_bytes_available : Bool = true

    # For each hash, the stream position that last had it.
    @head : UInt32* = Pointer(UInt32).null
    # For each position (modulo the window), the distance back to the
    # previous position with the same hash, or 0.
    @previous : UInt16* = Pointer(UInt16).null
    @symbols : UInt32* = Pointer(UInt32).null
    @symbol_count : Int32 = 0

    # The lazy matcher's state between calls: the match found at the
    # previous position and whether that position's byte is still unsent.
    @match_length : Int32 = MIN_MATCH - 1
    @match_distance : UInt32 = 0_u32
    @match_available : Bool = false
    # Positions before `@position` that were too close to the end of the
    # input to hash; they are hashed when more input arrives.
    @unhashed_positions : Int32 = 0

    @checksum : UInt32
    @input_size : UInt32 = 0_u32
    @header_written : Bool = false
    @flushed : Bool = false
    getter? finished : Bool = false

    # *sink* receives the stream as it is produced; without one the output
    # collects for `result`. *expected_input_bytes* sizes the first output
    # buffer and, for a short one-shot input, the tables.
    def initialize(@format : Format, @level : Int32, sink : IO?, @dictionary : Bytes? = nil,
                   @header : Gzip::Header? = nil, expected_input_bytes : Int32 = -1)
      Deflater.check_level(@level)
      @parameters = LEVELS[@level]
      check_header
      capacity = sink ? STREAM_OUTPUT_BYTES : Math.max(expected_input_bytes // 2, 0) + 1_024
      @blocks = BlockWriter.new(sink, capacity)
      @checksum = @format.zlib? ? 1_u32 : 0_u32
      if @level > 0
        chain_entries = WINDOW
        symbol_entries = SYMBOL_LIMIT + 1
        if expected_input_bytes >= 0 && @dictionary.nil?
          chain_entries = Math.min(chain_entries, expected_input_bytes + 1)
          symbol_entries = Math.min(symbol_entries, expected_input_bytes + 1)
        end
        @head = Pointer(UInt32).malloc(HASH_SIZE)
        @previous = GC.malloc_atomic(chain_entries.to_u64 * 2).as(UInt16*)
        @symbols = GC.malloc_atomic(symbol_entries.to_u64 * 4).as(UInt32*)
      end
      load_dictionary
    end

    # Bytes the engine holds for the window, the hash and chain tables and
    # the symbol buffer.
    def table_bytes : Int32
      window = @window
      bytes = window ? window.size : 0
      bytes += HASH_SIZE * 4 + WINDOW * 2 + (SYMBOL_LIMIT + 1) * 4 if @level > 0
      bytes
    end

    # Bytes the engine holds for its output buffer.
    def output_buffer_bytes : Int32
      @blocks.buffer_bytes
    end

    # Encodes the whole of *input* where it lies. The engine reads *input*
    # until `finish` returns; this is the one-shot path and takes the place
    # of every `write`.
    def write_in_place(input : Bytes) : Nil
      write_header
      add_to_checksum(input)
      @source = input.to_unsafe
      @fill = input.size
    end

    # Copies *input* into the window and encodes what can be encoded
    # without knowing what follows.
    def write(input : Bytes) : Nil
      return if input.empty?
      write_header
      add_to_checksum(input)
      window = window_for_writing
      offset = 0
      while offset < input.size
        slide_window if @fill == WINDOW_CAPACITY
        count = Math.min(WINDOW_CAPACITY - @fill, input.size - offset)
        (window.to_unsafe + @fill).copy_from(input.to_unsafe + offset, count)
        @fill += count
        offset += count
        hash_the_unhashed_positions
        compress(false)
      end
      @flushed = false
    end

    # Ends the current block and appends an empty stored block, so that
    # everything written so far can be decoded and the output ends on a
    # byte boundary (zlib's Z_SYNC_FLUSH). With *is_full* the history is
    # dropped too: the bytes that follow refer to nothing before this
    # point (Z_FULL_FLUSH). A flush right after a flush writes nothing.
    def flush(is_full : Bool = false) : Nil
      unless @flushed
        write_header
        compress(true)
        write_block(false) if @symbol_count > 0 || (@level == 0 && @fill > @block_start)
        @blocks.write_sync_marker
        @flushed = true
      end
      drop_history if is_full
      @blocks.drain
    end

    # Writes the final block and the trailer. The stream is complete.
    def finish : Nil
      return if @finished
      write_header
      compress(true)
      write_block(true)
      write_trailer
      @blocks.drain
      @finished = true
    end

    # The whole stream, for a deflater without a sink.
    def result : Bytes
      @blocks.result
    end

    # ---- Containers ----------------------------------------------------

    private def check_header : Nil
      header = @header
      return unless header
      extra_field = header.extra_field
      if extra_field && extra_field.size > 65_535
        raise ArgumentError.new("A gzip extra field holds at most 65,535 bytes (got #{extra_field.size})")
      end
      check_no_zero_byte("file name", header.file_name)
      check_no_zero_byte("comment", header.comment)
    end

    private def check_no_zero_byte(field : String, bytes : Bytes?) : Nil
      return unless bytes
      raise ArgumentError.new("A gzip #{field} cannot contain a zero byte") if bytes.includes?(0_u8)
    end

    private def write_header : Nil
      return if @header_written
      @header_written = true
      if @format.zlib?
        write_zlib_header
      elsif @format.gzip?
        write_gzip_header
      end
    end

    # RFC 1950: CMF (method 8, a 32 KiB window), then FLG with the level
    # hint zlib writes, FDICT and the check bits; then the dictionary's
    # Adler-32 when there is one.
    private def write_zlib_header : Nil
      level_hint = if @level < 2
                     0_u32
                   elsif @level < 6
                     1_u32
                   elsif @level == 6
                     2_u32
                   else
                     3_u32
                   end
      header = (0x78_u32 << 8) | (level_hint << 6)
      dictionary = @dictionary
      header |= 0x20 if dictionary
      header += 31 - header % 31
      @blocks.write_byte((header >> 8).to_u8!)
      @blocks.write_byte(header.to_u8!)
      @blocks.write_u32_be(Adler32.update(1_u32, dictionary)) if dictionary
    end

    # RFC 1952: the fixed ten bytes, then FEXTRA, FNAME and FCOMMENT when
    # the header has them. Without a header the modification time is 0 and
    # the operating system 255 (unknown), so the same input always gives
    # the same bytes; XFL then says 2 for level 9 and 4 for levels 0 and 1,
    # as zlib does.
    private def write_gzip_header : Nil
      header = @header
      flags = 0_u8
      modification_time = 0_u32
      extra_flags = @level == 9 ? 2_u8 : (@level < 2 ? 4_u8 : 0_u8)
      operating_system = 255_u8
      if header
        flags |= 0x01 if header.is_text
        flags |= 0x04 if header.extra_field
        flags |= 0x08 if header.file_name
        flags |= 0x10 if header.comment
        modification_time = header.modification_time
        extra_flags = header.extra_flags
        operating_system = header.operating_system
      end
      @blocks.write_byte(Inflater::MAGIC[0])
      @blocks.write_byte(Inflater::MAGIC[1])
      @blocks.write_byte(8_u8)
      @blocks.write_byte(flags)
      @blocks.write_u32_le(modification_time)
      @blocks.write_byte(extra_flags)
      @blocks.write_byte(operating_system)
      return unless header
      if extra_field = header.extra_field
        @blocks.write_u16_le(extra_field.size.to_u32)
        @blocks.write_bytes(extra_field)
      end
      if file_name = header.file_name
        @blocks.write_bytes(file_name)
        @blocks.write_byte(0_u8)
      end
      if comment = header.comment
        @blocks.write_bytes(comment)
        @blocks.write_byte(0_u8)
      end
    end

    private def write_trailer : Nil
      if @format.zlib?
        @blocks.write_u32_be(@checksum)
      elsif @format.gzip?
        @blocks.write_u32_le(@checksum)
        @blocks.write_u32_le(@input_size)
      end
    end

    private def add_to_checksum(input : Bytes) : Nil
      if @format.zlib?
        @checksum = Adler32.update(@checksum, input)
      elsif @format.gzip?
        @checksum = CRC32.update(@checksum, input)
      end
      @input_size &+= input.size.to_u32!
    end

    # ---- The window ----------------------------------------------------

    private def window_for_writing : Bytes
      window = @window
      return window if window
      window = Bytes.new(GC.malloc_atomic(WINDOW_CAPACITY).as(UInt8*), WINDOW_CAPACITY)
      @window = window
      @source = window.to_unsafe
      window
    end

    # Puts the last 32 KiB of the preset dictionary in front of the input
    # and hashes it, so the first bytes can refer to it.
    private def load_dictionary : Nil
      dictionary = @dictionary
      return unless dictionary
      return if @level == 0 || dictionary.empty?
      tail = dictionary.size > WINDOW ? dictionary[dictionary.size - WINDOW, WINDOW] : dictionary
      window = window_for_writing
      window.to_unsafe.copy_from(tail.to_unsafe, tail.size)
      @fill = tail.size
      @position = tail.size
      @block_start = tail.size
      @unhashed_positions = tail.size
      hash_the_unhashed_positions
    end

    # Moves the history to the front of the window to make room. Offsets
    # move down by the same amount and `@base` up, so stream positions (what
    # the hash table holds) stay as they are.
    private def slide_window : Nil
      window = window_for_writing
      history = @level == 0 ? 0 : WINDOW_KEEP
      shift = @position - history
      return if shift <= 0
      window.to_unsafe.move_from(window.to_unsafe + shift, @fill - shift)
      @fill -= shift
      @position -= shift
      @block_start -= shift
      @block_bytes_available = false if @block_start < 0
      @base &+= shift.to_u32!
    end

    # Forgets everything before the current position (a full flush): no
    # match may reach back past it.
    private def drop_history : Nil
      return if @level == 0
      @head.clear(HASH_SIZE)
      @unhashed_positions = 0
      return unless @window
      # Everything is encoded, so the window restarts empty.
      @position = 0
      @fill = 0
      @block_start = 0
      @block_bytes_available = true
      @base = 0_u32
    end

    # ---- Blocks --------------------------------------------------------

    private def write_block(is_final : Bool) : Nil
      if @level == 0
        @blocks.write_stored(@source + @block_start, @fill - @block_start, is_final)
        @position = @fill
      else
        stored = @block_bytes_available ? @source + @block_start : Pointer(UInt8).null
        @blocks.write_block(@symbols, @symbol_count, stored, @position - @block_start, @block_bytes_available, is_final)
        @symbol_count = 0
      end
      @block_start = @position
      @block_bytes_available = true
    end

    # ---- Matching ------------------------------------------------------

    # Encodes from `@position` on. Unless *is_flushing*, it stops while
    # `MIN_LOOKAHEAD` bytes remain so that no match is cut short by input
    # that has not arrived.
    private def compress(is_flushing : Bool) : Nil
      if @level == 0
        store_whole_blocks
      elsif @parameters.is_lazy
        compress_lazily(is_flushing)
      else
        compress_greedily(is_flushing)
      end
    end

    # Level 0: writes each full 65,535 bytes as a stored block; the rest
    # waits for `write_block`.
    private def store_whole_blocks : Nil
      while @fill - @block_start >= BlockWriter::MAX_STORED_BYTES
        @blocks.write_stored(@source + @block_start, BlockWriter::MAX_STORED_BYTES, false)
        @block_start += BlockWriter::MAX_STORED_BYTES
      end
      @position = @block_start
    end

    @[AlwaysInline]
    private def load_u64(pointer : UInt8*) : UInt64
      value = uninitialized UInt64
      pointerof(value).as(UInt8*).copy_from(pointer, 8)
      {% if IO::ByteFormat::SystemEndian != IO::ByteFormat::LittleEndian %}
        value = value.byte_swap
      {% end %}
      value
    end

    @[AlwaysInline]
    private def load_u16(pointer : UInt8*) : UInt16
      value = uninitialized UInt16
      pointerof(value).as(UInt8*).copy_from(pointer, 2)
      value
    end

    # zlib's hash of the three bytes at *pointer*.
    @[AlwaysInline]
    private def hash_at(pointer : UInt8*) : UInt32
      ((pointer[0].to_u32 << 10) ^ (pointer[1].to_u32 << 5) ^ pointer[2].to_u32) & HASH_MASK
    end

    # Records the position at offset *offset* under its hash and returns
    # its distance to the previous position with that hash (a value past
    # the window when there is none).
    @[AlwaysInline]
    private def insert_position(source : UInt8*, head : UInt32*, previous : UInt16*, base : UInt32, offset : Int32) : UInt32
      hash = hash_at(source + offset)
      stream_position = base &+ offset.to_u32!
      distance = stream_position &- head[hash]
      head[hash] = stream_position
      previous[stream_position & WINDOW_MASK] = distance < 65_536_u32 ? distance.to_u16! : 0_u16
      distance
    end

    # Returns how many of the first *limit* bytes at *first* and *second*
    # are equal, comparing eight bytes at a time.
    @[AlwaysInline]
    private def common_length(first : UInt8*, second : UInt8*, limit : Int32) : Int32
      length = 0
      while length &+ 8 <= limit
        difference = load_u64(first + length) ^ load_u64(second + length)
        if difference != 0
          return length &+ (difference.trailing_zeros_count >> 3)
        end
        length &+= 8
      end
      while length < limit && first[length] == second[length]
        length &+= 1
      end
      length
    end

    # Walks the hash chain from the candidate *distance* back (zlib's
    # `longest_match`) and returns the longest match longer than
    # *best_length* with its distance, or *best_length* and 0. A candidate
    # is compared in full only when its two bytes at the current best
    # length match, since only then can it be longer.
    @[AlwaysInline]
    private def longest_match(scan : UInt8*, previous : UInt16*, stream_position : UInt32, distance : UInt32,
                              max_distance : UInt32, best_length : Int32, nice_length : Int32, chain : Int32,
                              max_length : Int32) : {Int32, UInt32}
      best_distance = 0_u32
      return {best_length, best_distance} if best_length >= max_length
      scan_end = load_u16(scan + (best_length &- 1))
      loop do
        candidate = scan - distance
        if load_u16(candidate + (best_length &- 1)) == scan_end
          length = common_length(scan, candidate, max_length)
          if length > best_length
            best_length = length
            best_distance = distance
            break if length >= nice_length
            scan_end = load_u16(scan + (best_length &- 1))
          end
        end
        step = previous[(stream_position &- distance) & WINDOW_MASK]
        break if step == 0
        distance &+= step
        break if distance > max_distance
        chain &-= 1
        break if chain == 0
      end
      {best_length, best_distance}
    end

    # Levels 1 to 3 (zlib's `deflate_fast`): take the longest match at each
    # position, or a literal.
    private def compress_greedily(is_flushing : Bool) : Nil
      source = @source
      head = @head
      previous = @previous
      symbols = @symbols
      literal_frequencies = @blocks.literal_frequencies
      distance_frequencies = @blocks.distance_frequencies
      length_symbols = BlockWriter::LENGTH_SYMBOLS.to_unsafe
      distance_symbols = BlockWriter::DISTANCE_SYMBOLS.to_unsafe
      base = @base
      position = @position
      fill = @fill
      symbol_count = @symbol_count
      nice_length = @parameters.nice_length
      max_chain = @parameters.max_chain
      max_insert = @parameters.max_lazy

      loop do
        lookahead = fill &- position
        if lookahead < MIN_LOOKAHEAD
          break if !is_flushing || lookahead == 0
        end
        length = MIN_MATCH - 1
        match_distance = 0_u32
        if lookahead >= MIN_MATCH
          distance = insert_position(source, head, previous, base, position)
          max_distance = Math.min(Math.max(position &- 1, 0), WINDOW).to_u32!
          if distance &- 1 < max_distance
            length, match_distance = longest_match(source + position, previous, base &+ position.to_u32!, distance,
              max_distance, MIN_MATCH - 1, Math.min(nice_length, lookahead), max_chain, Math.min(MAX_MATCH, lookahead))
          end
        end

        if length >= MIN_MATCH
          symbols[symbol_count] = (match_distance << 8) | (length &- MIN_MATCH).to_u32!
          symbol_count &+= 1
          literal_frequencies[257 &+ length_symbols[length &- MIN_MATCH]] &+= 1
          code = match_distance &- 1
          distance_frequencies[code < 256 ? distance_symbols[code] : distance_symbols[256_u32 &+ (code >> 7)]] &+= 1
          match_end = position &+ length
          if length <= max_insert && fill &- match_end >= MIN_MATCH
            position &+= 1
            while position < match_end
              insert_position(source, head, previous, base, position)
              position &+= 1
            end
          else
            position = match_end
          end
        else
          byte = source[position]
          symbols[symbol_count] = byte.to_u32
          symbol_count &+= 1
          literal_frequencies[byte] &+= 1
          position &+= 1
        end

        if symbol_count == SYMBOL_LIMIT
          @position = position
          @symbol_count = symbol_count
          write_block(false)
          symbol_count = 0
        end
      end

      @position = position
      @symbol_count = symbol_count
      @unhashed_positions = Math.min(position, MIN_MATCH - 1) if is_flushing
    end

    # Levels 4 to 9 (zlib's `deflate_slow`): a match found at one position
    # is sent only if the next position has none longer; otherwise the
    # byte goes out as a literal and the longer match takes over.
    private def compress_lazily(is_flushing : Bool) : Nil
      source = @source
      head = @head
      previous = @previous
      symbols = @symbols
      literal_frequencies = @blocks.literal_frequencies
      distance_frequencies = @blocks.distance_frequencies
      length_symbols = BlockWriter::LENGTH_SYMBOLS.to_unsafe
      distance_symbols = BlockWriter::DISTANCE_SYMBOLS.to_unsafe
      base = @base
      position = @position
      fill = @fill
      symbol_count = @symbol_count
      good_length = @parameters.good_length
      max_lazy = @parameters.max_lazy
      nice_length = @parameters.nice_length
      max_chain = @parameters.max_chain
      match_length = @match_length
      match_distance = @match_distance
      is_byte_pending = @match_available

      loop do
        lookahead = fill &- position
        if lookahead < MIN_LOOKAHEAD
          break if !is_flushing || lookahead == 0
        end
        previous_length = match_length
        previous_distance = match_distance
        match_length = MIN_MATCH - 1
        if lookahead >= MIN_MATCH
          distance = insert_position(source, head, previous, base, position)
          max_distance = Math.min(Math.max(position &- 1, 0), WINDOW).to_u32!
          if previous_length < max_lazy && distance &- 1 < max_distance
            chain = previous_length >= good_length ? max_chain >> 2 : max_chain
            match_length, found_distance = longest_match(source + position, previous, base &+ position.to_u32!, distance,
              max_distance, previous_length, Math.min(nice_length, lookahead), chain, Math.min(MAX_MATCH, lookahead))
            if match_length > previous_length
              match_distance = found_distance
              match_length = MIN_MATCH - 1 if match_length == MIN_MATCH && match_distance > TOO_FAR
            end
          end
        end

        if previous_length >= MIN_MATCH && match_length <= previous_length
          # The match found at the previous position stands.
          symbols[symbol_count] = (previous_distance << 8) | (previous_length &- MIN_MATCH).to_u32!
          symbol_count &+= 1
          literal_frequencies[257 &+ length_symbols[previous_length &- MIN_MATCH]] &+= 1
          code = previous_distance &- 1
          distance_frequencies[code < 256 ? distance_symbols[code] : distance_symbols[256_u32 &+ (code >> 7)]] &+= 1
          match_end = position &+ previous_length &- 1
          last_hashable = fill &- MIN_MATCH
          position &+= 1
          while position < match_end
            insert_position(source, head, previous, base, position) if position <= last_hashable
            position &+= 1
          end
          is_byte_pending = false
          match_length = MIN_MATCH - 1
          if symbol_count == SYMBOL_LIMIT
            @position = position
            @symbol_count = symbol_count
            write_block(false)
            symbol_count = 0
          end
        elsif is_byte_pending
          byte = source[position &- 1]
          symbols[symbol_count] = byte.to_u32
          symbol_count &+= 1
          literal_frequencies[byte] &+= 1
          if symbol_count == SYMBOL_LIMIT
            @position = position
            @symbol_count = symbol_count
            write_block(false)
            symbol_count = 0
          end
          position &+= 1
        else
          is_byte_pending = true
          position &+= 1
        end
      end

      if is_flushing
        if is_byte_pending
          byte = source[position &- 1]
          symbols[symbol_count] = byte.to_u32
          symbol_count &+= 1
          literal_frequencies[byte] &+= 1
          is_byte_pending = false
        end
        match_length = MIN_MATCH - 1
        @unhashed_positions = Math.min(position, MIN_MATCH - 1)
      end
      @position = position
      @symbol_count = symbol_count
      @match_length = match_length
      @match_distance = match_distance
      @match_available = is_byte_pending
    end

    # Hashes the positions a flush or the dictionary left unhashed, now
    # that the bytes after them are known.
    private def hash_the_unhashed_positions : Nil
      return if @level == 0
      while @unhashed_positions > 0 && @position - @unhashed_positions + MIN_MATCH <= @fill
        insert_position(@source, @head, @previous, @base, @position - @unhashed_positions)
        @unhashed_positions -= 1
      end
    end
  end
end
