# The reference decoder for the Mica::Deflate differential: the system zlib,
# bound here for the fuzz harness and the specs only (the library in src/
# links no C code). `DeflateOracle` decodes raw DEFLATE, zlib and gzip
# under the acceptance semantics Mica::Deflate, Mica::Zlib and Mica::Gzip
# implement, and compresses the harness's valid seed streams.
#
# scripts/zlib_oracle_identity.sh prints which zlib this is.

@[Link("z")]
lib LibZOracle
  alias Int = LibC::Int
  alias UInt = LibC::UInt
  alias ULong = LibC::ULong

  # z_stream of zlib.h.
  struct ZStream
    next_in : UInt8*
    avail_in : UInt
    total_in : ULong
    next_out : UInt8*
    avail_out : UInt
    total_out : ULong
    msg : LibC::Char*
    state : Void*
    zalloc : Void*
    zfree : Void*
    opaque : Void*
    data_type : Int
    adler : ULong
    reserved : ULong
  end

  fun zlibVersion : LibC::Char*
  fun inflateInit2_(stream : ZStream*, window_bits : Int, version : LibC::Char*, stream_size : Int) : Int
  fun inflate(stream : ZStream*, flush : Int) : Int
  fun inflateEnd(stream : ZStream*) : Int
  fun inflateReset2(stream : ZStream*, window_bits : Int) : Int
  fun inflateSetDictionary(stream : ZStream*, dictionary : UInt8*, length : UInt) : Int
  fun deflateInit2_(stream : ZStream*, level : Int, method : Int, window_bits : Int, memory_level : Int,
                    strategy : Int, version : LibC::Char*, stream_size : Int) : Int
  fun deflate(stream : ZStream*, flush : Int) : Int
  fun deflateEnd(stream : ZStream*) : Int
  fun deflateSetDictionary(stream : ZStream*, dictionary : UInt8*, length : UInt) : Int
  fun crc32(crc : ULong, bytes : UInt8*, length : UInt) : ULong
  fun adler32(adler : ULong, bytes : UInt8*, length : UInt) : ULong
end

module DeflateOracle
  # The three containers, shared with the fuzz cases.
  enum Format
    Raw
    Zlib
    Gzip

    # The windowBits value that selects this container in zlib.
    def window_bits(bits : Int32 = 15) : Int32
      if raw?
        -bits
      elsif zlib?
        bits
      else
        bits + 16
      end
    end
  end

  # Why the oracle rejected a stream.
  enum Rejection
    # zlib reported a data error (Z_DATA_ERROR), or a byte follows the stream.
    Malformed
    # The input ended inside the stream.
    Truncated
    # The stream asks for a preset dictionary and none, or the wrong one, was given.
    Dictionary
    # The output passed the caller's cap before the stream ended.
    OverCap
  end

  # What the oracle made of one input. *output* holds every byte zlib
  # produced, also when the stream was rejected afterwards.
  record Result, output : Bytes, rejection : Rejection?, detail : String, members : Int32 do
    # Returns true when the whole input is one valid stream.
    def accepted? : Bool
      @rejection.nil?
    end

    # Returns true when the stream was rejected for its content (not for the cap).
    def rejected? : Bool
      rejection = @rejection
      !rejection.nil? && !rejection.over_cap?
    end
  end

  # zlib's deflate strategies.
  enum Strategy
    Default     = 0
    Filtered    = 1
    HuffmanOnly = 2
    RLE         = 3
    Fixed       = 4
  end

  # zlib's flush modes for `compress` steps.
  enum Flush
    None    = 0
    Partial = 1
    Sync    = 2
    Full    = 3
    Finish  = 4
    Block   = 5
  end

  Z_OK         =  0
  Z_STREAM_END =  1
  Z_NEED_DICT  =  2
  Z_DATA_ERROR = -3
  Z_BUF_ERROR  = -5
  Z_DEFLATED   =  8

  FIRST_OUTPUT_BYTES = 16_384
  DEFAULT_CAP        = 256_i64 * 1024 * 1024

  # Returns the linked zlib's version string.
  def self.version : String
    String.new(LibZOracle.zlibVersion)
  end

  # Returns the CRC-32 of *bytes*, continuing from *crc* (0 to start).
  def self.crc32(bytes : Bytes, crc : UInt32 = 0_u32) : UInt32
    LibZOracle.crc32(crc, bytes.to_unsafe, bytes.size).to_u32!
  end

  # Returns the Adler-32 of *bytes*, continuing from *adler* (1 to start).
  def self.adler32(bytes : Bytes, adler : UInt32 = 1_u32) : UInt32
    LibZOracle.adler32(adler, bytes.to_unsafe, bytes.size).to_u32!
  end

  # Decodes *input* as *format*. The whole input goes to zlib in one call
  # and the output buffer grows as needed, up to *cap* bytes.
  #
  # - Raw and zlib: accepted when zlib reports the end of the stream and no
  #   input byte is left.
  # - Gzip: one member after another (`inflateReset2` between them) until
  #   the input ends; any byte after a member must start another member.
  # - *dictionary* answers zlib's request for a preset dictionary; for raw
  #   streams it is set before the first byte (the harness uses that to
  #   compute checksums of hand-built streams).
  def self.decode(format : Format, input : Bytes, dictionary : Bytes? = nil, cap : Int64 = DEFAULT_CAP) : Result
    stream = LibZOracle::ZStream.new
    status = LibZOracle.inflateInit2_(pointerof(stream), format.window_bits, LibZOracle.zlibVersion, sizeof(LibZOracle::ZStream))
    raise "inflateInit2 failed: #{status}" unless status == Z_OK
    begin
      if format.raw? && dictionary
        status = LibZOracle.inflateSetDictionary(pointerof(stream), dictionary.to_unsafe, dictionary.size)
        raise "inflateSetDictionary failed on a raw stream: #{status}" unless status == Z_OK
      end
      inflate_all(pointerof(stream), format, input, dictionary, cap)
    ensure
      LibZOracle.inflateEnd(pointerof(stream))
    end
  end

  private def self.inflate_all(stream : LibZOracle::ZStream*, format : Format, input : Bytes, dictionary : Bytes?, cap : Int64) : Result
    output = Bytes.new(Math.min(FIRST_OUTPUT_BYTES.to_i64, Math.max(cap, 1_i64)).to_i32)
    produced = 0
    members = 0
    stream.value.next_in = input.to_unsafe
    stream.value.avail_in = input.size.to_u32
    loop do
      if produced == output.size
        return Result.new(output, Rejection::OverCap, "output passes #{cap} bytes", members) if produced >= cap
        larger = Bytes.new(Math.min(output.size.to_i64 * 2, cap).to_i32)
        larger.copy_from(output)
        output = larger
      end
      stream.value.next_out = output.to_unsafe + produced
      stream.value.avail_out = (output.size - produced).to_u32
      status = LibZOracle.inflate(stream, 0)
      produced = output.size - stream.value.avail_out.to_i32
      case status
      when Z_STREAM_END
        members += 1
        return Result.new(output[0, produced], nil, "", members) if stream.value.avail_in == 0
        unless format.gzip?
          return Result.new(output[0, produced], Rejection::Malformed, "#{stream.value.avail_in} bytes after the stream", members)
        end
        status = LibZOracle.inflateReset2(stream, format.window_bits)
        raise "inflateReset2 failed: #{status}" unless status == Z_OK
      when Z_OK
        if stream.value.avail_in == 0 && stream.value.avail_out != 0
          return Result.new(output[0, produced], Rejection::Truncated, "input ended inside the stream", members)
        end
      when Z_BUF_ERROR
        if stream.value.avail_out != 0
          return Result.new(output[0, produced], Rejection::Truncated, "input ended inside the stream", members)
        end
      when Z_NEED_DICT
        unless dictionary
          return Result.new(output[0, produced], Rejection::Dictionary, "preset dictionary required", members)
        end
        status = LibZOracle.inflateSetDictionary(stream, dictionary.to_unsafe, dictionary.size)
        unless status == Z_OK
          return Result.new(output[0, produced], Rejection::Dictionary, "preset dictionary does not match", members)
        end
      else
        message = stream.value.msg
        detail = message.null? ? "zlib status #{status}" : String.new(message)
        return Result.new(output[0, produced], Rejection::Malformed, detail, members)
      end
    end
  end

  # One step of a `compress` call: *size* more input bytes, then *flush*.
  record Step, size : Int32, flush : Flush

  # Compresses *data* with zlib's deflate into *format*. *steps* cuts the
  # input into pieces, each followed by a flush; whatever is left is
  # finished at the end. *dictionary* presets the window (zlib format: the
  # header then carries FDICT).
  def self.compress(data : Bytes, format : Format = Format::Raw, level : Int32 = 6, strategy : Strategy = Strategy::Default,
                    window_bits : Int32 = 15, memory_level : Int32 = 8, steps : Array(Step) = [] of Step,
                    dictionary : Bytes? = nil) : Bytes
    stream = LibZOracle::ZStream.new
    status = LibZOracle.deflateInit2_(pointerof(stream), level, Z_DEFLATED, format.window_bits(window_bits), memory_level,
      strategy.value, LibZOracle.zlibVersion, sizeof(LibZOracle::ZStream))
    raise "deflateInit2 failed: #{status}" unless status == Z_OK
    begin
      if dictionary
        status = LibZOracle.deflateSetDictionary(pointerof(stream), dictionary.to_unsafe, dictionary.size)
        raise "deflateSetDictionary failed: #{status}" unless status == Z_OK
      end
      compressed = IO::Memory.new
      offset = 0
      steps.each do |step|
        size = Math.min(step.size, data.size - offset)
        deflate_piece(pointerof(stream), data[offset, size], step.flush, compressed)
        offset += size
      end
      deflate_piece(pointerof(stream), data[offset, data.size - offset], Flush::Finish, compressed)
      compressed.to_slice
    ensure
      LibZOracle.deflateEnd(pointerof(stream))
    end
  end

  private def self.deflate_piece(stream : LibZOracle::ZStream*, piece : Bytes, flush : Flush, compressed : IO::Memory) : Nil
    buffer = uninitialized UInt8[16_384]
    stream.value.next_in = piece.to_unsafe
    stream.value.avail_in = piece.size.to_u32
    loop do
      stream.value.next_out = buffer.to_unsafe
      stream.value.avail_out = buffer.size.to_u32
      status = LibZOracle.deflate(stream, flush.value)
      written = buffer.size - stream.value.avail_out.to_i32
      compressed.write(buffer.to_slice[0, written])
      break if status == Z_STREAM_END
      # Z_BUF_ERROR here means a flush found nothing more to do.
      raise "deflate failed: #{status}" unless status == Z_OK || status == Z_BUF_ERROR
      break if stream.value.avail_out != 0 && !flush.finish?
    end
  end
end
