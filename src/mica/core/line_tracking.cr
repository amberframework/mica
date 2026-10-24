module Mica::Core
  # Line and column tracking for text formats, included next to `ByteInput`.
  #
  # The scanner calls `record_line_break` after each line end it consumes
  # (each format decides what a line end is). Columns are not counted while
  # scanning: `column_at` counts the characters (UTF-8 lead bytes) between
  # the line start and a position when one is asked for. A cache of the last
  # answer makes repeated questions on the same line cost only the distance
  # moved, so asking for the position after every event stays linear in the
  # input size even on a single-line document.
  module LineTracking
    @line = 1
    @line_start = 0_i64
    @column_offset = 0
    @column_cache_offset = -1_i64
    @column_cache_value = 0
    @column_cache_line_start = -1_i64
    # Bytes examined by `column_at`, for work accounting.
    @column_steps = 0_i64

    # Records a line end; the next line starts at decoded offset
    # *next_line_start*.
    @[AlwaysInline]
    private def record_line_break(next_line_start : Int64) : Nil
      @line += 1
      @line_start = next_line_start
      @column_offset = 0
    end

    # Folds the characters between the line start and the end of the bytes
    # about to be discarded (`buffer[0, keep]`, first byte at decoded offset
    # *base*) into `@column_offset`, so columns stay exact after the buffer
    # moves. Each discarded byte is counted at most once.
    private def fold_discarded_columns(buffer : Bytes, keep : Int32, base : Int64) : Nil
      discard_end = base + keep
      return unless @line_start < discard_end
      from = Math.max(@line_start - base, 0_i64).to_i32
      discarded = buffer[from, keep - from]
      # Characters are the bytes that are not UTF-8 continuation bytes.
      @column_offset += discarded.size - discarded.count { |byte| byte & 0xC0 == 0x80 }
      @line_start = discard_end
      @column_cache_offset = -1_i64
    end

    # Returns the 1-based column of byte *pos* of *buffer* (first byte at
    # decoded offset *base*) on the current line.
    private def column_at(buffer : Bytes, pos : Int32, base : Int64) : Int32
      absolute = base + pos
      return (absolute - @line_start).to_i32 + 1 if @line_start < base || @line_start > absolute
      start = (@line_start - base).to_i32
      column = 1 + @column_offset
      cached = @column_cache_offset
      if @column_cache_line_start == @line_start && cached >= @line_start && cached >= base && cached <= absolute
        start = (cached - base).to_i32
        column = @column_cache_value
      end
      index = start
      @column_steps += pos - start if pos > start
      while index < pos
        column += 1 unless buffer[index] & 0xC0 == 0x80
        index += 1
      end
      @column_cache_offset = absolute
      @column_cache_value = column
      @column_cache_line_start = @line_start
      column
    end
  end
end
