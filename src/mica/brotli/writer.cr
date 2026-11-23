module Mica::Brotli
  # Encodes a Brotli stream (RFC 7932) as it is written.
  #
  # Input is buffered until a metablock's worth (256 KiB below quality 5,
  # 1 MiB from 5) is ready. `flush` encodes what is buffered and ends on a
  # byte boundary with an empty metadata metablock, so a decoder that has
  # read the output up to there can decode every byte written before the
  # call; `close` writes the last metablock.
  #
  # ```
  # writer = Mica::Brotli::Writer.new(io, quality: 5)
  # writer.write(body)
  # writer.close
  # ```
  class Writer < IO
    # Whether `close` also closes the destination.
    property? sync_close : Bool

    # Returns true once closed.
    getter? closed : Bool = false

    @destination : IO
    @stream_encoder : Brotli::Encoder
    @bits = BitWriter.new
    @buffer : Bytes
    @filled = 0
    @pending_start = 0
    @stream_offset = 0_i64
    @window : Int32
    @capacity : Int32
    @wrote_since_flush = false

    # Raises `ArgumentError` unless *quality* is 0 to 11 and *window_bits*
    # 10 to 24.
    def initialize(@destination : IO, *, quality : Int32 = 5, window_bits : Int32 = 22, @sync_close : Bool = false)
      Brotli::Encoder.check(quality, window_bits)
      @window = 1 << window_bits
      @stream_encoder = Brotli::Encoder.new(quality, window_bits, @window)
      @capacity = 2 * @window + @stream_encoder.metablock_size
      @buffer = Bytes.new(Math.min(@capacity, 1 << 16))
    end

    # Raises `IO::Error`: the writer is write-only.
    def read(slice : Bytes) : NoReturn
      raise IO::Error.new("Can't read from #{self.class}")
    end

    # Buffers *slice*, encoding each full metablock.
    def write(slice : Bytes) : Nil
      check_open
      return if slice.empty?
      @wrote_since_flush = true
      remaining = slice
      until remaining.empty?
        make_room
        count = Math.min(remaining.size, @buffer.size - @filled)
        (@buffer.to_unsafe + @filled).copy_from(remaining.to_unsafe, count)
        @filled += count
        remaining += count
        while @filled - @pending_start >= @stream_encoder.metablock_size
          encode_pending(@stream_encoder.metablock_size, is_last: false)
        end
      end
    end

    # Encodes everything written so far, ends on a byte boundary and
    # flushes the destination. A flush with nothing written since the
    # last one adds no bytes.
    def flush : Nil
      return if @closed
      if @wrote_since_flush
        encode_pending(@filled - @pending_start, is_last: false) if @filled > @pending_start
        @stream_encoder.write_flush_marker(@bits)
        @bits.drain(@destination)
        @wrote_since_flush = false
      end
      @destination.flush
    end

    # Writes the last metablock, flushes the destination and, with
    # `sync_close?`, closes it.
    def close : Nil
      return if @closed
      @closed = true
      encode_pending(@filled - @pending_start, is_last: true)
      @destination.flush
      @destination.close if @sync_close
    end

    private def encode_pending(count : Int32, *, is_last : Bool) : Nil
      @stream_encoder.encode_block(@bits, @buffer[0, @filled], @pending_start, count, @stream_offset, is_last: is_last)
      @pending_start += count
      @bits.drain(@destination)
    end

    # Grows the buffer toward its capacity, or drops whole windows of
    # history that no match can reach any more.
    private def make_room : Nil
      return if @filled < @buffer.size
      if @buffer.size < @capacity
        grown = Bytes.new(Math.min(@capacity, @buffer.size * 2))
        grown.copy_from(@buffer.to_unsafe, @filled)
        @buffer = grown
        return
      end
      offset = ((@pending_start - @window) // @window) * @window
      return if offset <= 0
      @buffer.to_unsafe.move_from(@buffer.to_unsafe + offset, @filled - offset)
      @filled -= offset
      @pending_start -= offset
      @stream_offset += offset
      @stream_encoder.shift(offset)
    end
  end
end
