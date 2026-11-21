module Mica::Deflate
  # The streaming reader shared by `Deflate::Reader`, `Zlib::Reader` and
  # `Gzip::Reader`: an `IO` that decodes its source as it is read.
  #
  # :nodoc:
  abstract class StreamReader < IO
    # Whether `close` also closes the source.
    property? sync_close : Bool

    # Returns true once closed.
    getter? closed : Bool = false

    @source : IO
    @inflater : Inflater

    def initialize(@source : IO, format : Format, limits : DecodeLimits, timeout : Time::Span?, dictionary : Bytes?,
                   @sync_close : Bool)
      @inflater = Inflater.new(@source, format, limits, timeout, dictionary)
    end

    # Reads decoded bytes into *slice*; returns 0 at the end of the stream,
    # after every check value has passed.
    def read(slice : Bytes) : Int32
      check_open
      return 0 if slice.empty?
      loop do
        pending = @inflater.pending
        unless pending.empty?
          count = Math.min(pending.size, slice.size)
          slice.copy_from(pending.to_unsafe, count)
          @inflater.take(count)
          return count
        end
        return 0 unless @inflater.produce
      end
    end

    # Raises `IO::Error`: the reader is read-only.
    def write(slice : Bytes) : NoReturn
      raise IO::Error.new("Can't write to #{self.class}")
    end

    # Decoded bytes so far.
    def produced : Int64
      @inflater.produced
    end

    def close : Nil
      return if @closed
      @closed = true
      @source.close if @sync_close
    end
  end

  # Decodes a raw DEFLATE stream (RFC 1951) as it is read.
  #
  # ```
  # reader = Mica::Deflate::Reader.new(io, limits: Mica::Deflate::DecodeLimits::REQUEST_BODY, timeout: 2.seconds)
  # body = reader.gets_to_end
  # ```
  class Reader < StreamReader
    def initialize(io : IO, *, limits : DecodeLimits, timeout : Time::Span?, sync_close : Bool = false)
      super(io, Format::Raw, limits, timeout, nil, sync_close)
    end
  end
end
