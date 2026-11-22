# Round-trip fuzzing of the Mica::Deflate, Mica::Zlib and Mica::Gzip
# encoders (milestone Z2). Every case is built from a seed and an
# iteration number: an input from one of six families, a container, a
# level, sometimes a preset dictionary or a gzip header, and a way of
# writing it (one write, byte by byte, random pieces or 64 KiB pieces, with
# or without flushes). The input is encoded twice, in one call and through
# the Writer, and each stream must decode to the input in the system zlib
# (fuzz/deflate_oracle.cr) and in Mica's own decoder.
#
# Replay one case with DeflateEncodeFuzz.case_for(seed, iteration) and
# DeflateEncodeFuzz.failures_of(kase). The release campaign is
# fuzz/deflate_encode_campaign.cr; spec/deflate/encode_fuzz_spec.cr runs a
# small slice.
require "../src/mica"
require "./deflate_fuzz"

module DeflateEncodeFuzz
  alias Format = DeflateOracle::Format

  LIMITS = Mica::Deflate::DecodeLimits::TRUSTED_ASSET

  # What the inputs look like.
  enum Family
    # Bytes with no structure.
    Random
    # Words, spaces and line breaks.
    Text
    # Runs, short periods, repeats at chosen distances, small alphabets.
    Repetitive
    # A slice of a real HTTP body (bench/deflate/corpus/http).
    CorpusSlice
    # 0 to 16 bytes.
    Tiny
    # Sizes within 3 bytes of a size the encoder treats specially: the
    # longest match, the lookahead, a full symbol buffer, the window, a
    # stored block, the streaming window.
    WindowBoundary
  end

  # How the Writer receives the input.
  enum Chunking
    OneWrite
    ByteByByte
    RandomPieces
    LargePieces
  end

  # Input sizes: the campaign's, and a smaller set for the spec's debug build.
  record Profile, max_bytes : Int32, list_of_boundaries : Array(Int32) do
    FULL  = new(160_000, [258, 262, 16_383, 32_768, 32_769, 65_535, 65_536, 66_560, 98_304, 131_072, 196_608])
    QUICK = new(6_000, [258, 262, 16_383, 32_768])
  end

  record Case, family : Family, format : Format, level : Int32, input : Bytes, dictionary : Bytes?,
    header : Mica::Gzip::Header?, chunking : Chunking, flush_one_in : Int32, writer_seed : UInt64 do
    def to_s(io : IO) : Nil
      io << family << ' ' << format << " level " << level << ", " << input.size << " bytes, " << chunking
      io << ", flush 1 in " << flush_one_in if flush_one_in > 0
      if dictionary = @dictionary
        io << ", dictionary of " << dictionary.size
      end
      io << ", gzip header" if @header
    end
  end

  WORDS = %w[the of and to in is that it was for on are as with they at be this have from or one had by word but not
    what all were we when your can said there use an each which she do how their if will up other about out many
    then them these so some her would make like him into time has look two more write go see number no way could
    people my than first water been call who oil its now find long down day did get come made may part <div> </div>
    <p> </p> {"id": "name": "url": https:// null true false Content-Type: text/html; charset=utf-8 0123456789]

  CORPUS_NAMES = %w[html_1k.html html_16k.html html_64k.html html_1m.html json_1k.json json_16k.json json_64k.json]
  CORPUS       = CORPUS_NAMES.map { |name| File.open(File.join(__DIR__, "../bench/deflate/corpus/http", name), &.getb_to_end) }

  # A size from 0 to *max*, small sizes as likely as large ones.
  def self.size_up_to(random : Random, max : Int32) : Int32
    return 0 if max <= 0
    ((max + 1).to_f ** random.rand).to_i - 1
  end

  def self.text(random : Random, size : Int32) : Bytes
    io = IO::Memory.new(size + 32)
    while io.pos < size
      io << WORDS[random.rand(WORDS.size)]
      io << (random.rand(10) == 0 ? "\n" : " ")
    end
    io.to_slice[0, size]
  end

  # Segments that repeat: one byte, a short period, an earlier stretch
  # copied from a chosen distance, or bytes from a small alphabet.
  def self.repetitive(random : Random, size : Int32) : Bytes
    bytes = Bytes.new(size)
    position = 0
    while position < size
      length = Math.min(size - position, 1 + size_up_to(random, Math.max(size // 2, 300)))
      case random.rand(4)
      when 0
        bytes[position, length].fill(random.rand(256).to_u8)
      when 1
        period = random.rand(1..9)
        pattern = random.random_bytes(period)
        length.times { |index| bytes[position + index] = pattern[index % period] }
      when 2
        distance = {1, 2, 3, 4, 8, 255, 256, 257, 258, 259, 1_000, 4_096, 4_097, 32_767, 32_768, 32_769}.sample(random)
        if distance <= position
          length.times { |index| bytes[position + index] = bytes[position + index - distance] }
        else
          random.random_bytes(bytes[position, length])
        end
      else
        alphabet = random.rand(2..6)
        length.times { |index| bytes[position + index] = (97 + random.rand(alphabet)).to_u8 }
      end
      position += length
    end
    bytes
  end

  def self.corpus_slice(random : Random, max : Int32) : Bytes
    file = CORPUS[random.rand(CORPUS.size)]
    size = Math.min(size_up_to(random, max), file.size)
    file[random.rand(file.size - size + 1), size]
  end

  def self.window_boundary(random : Random, profile : Profile) : Bytes
    size = Math.max(profile.list_of_boundaries.sample(random) + random.rand(-3..3), 0)
    case random.rand(5)
    when 0 then random.random_bytes(size)
    when 1 then text(random, size)
    when 2 then Bytes.new(size, random.rand(256).to_u8)
    when 3
      # A block that repeats with a period within a byte of the window.
      period = 32_768 + random.rand(-1..1)
      block = random.random_bytes(Math.min(period, size))
      Bytes.new(size) { |index| block[index % period]? || 0_u8 }
    else repetitive(random, size)
    end
  end

  def self.input_of(random : Random, family : Family, profile : Profile) : Bytes
    case family
    in .random?          then random.random_bytes(size_up_to(random, profile.max_bytes // 2))
    in .text?            then text(random, size_up_to(random, profile.max_bytes))
    in .repetitive?      then repetitive(random, size_up_to(random, profile.max_bytes))
    in .corpus_slice?    then corpus_slice(random, profile.max_bytes)
    in .tiny?            then random.rand(2) == 0 ? random.random_bytes(random.rand(17)) : text(random, random.rand(17))
    in .window_boundary? then window_boundary(random, profile)
    end
  end

  # A preset dictionary: a stretch of the input (so the data refers to
  # it), text, or random bytes; sometimes longer than the window.
  def self.dictionary_for(random : Random, input : Bytes, profile : Profile) : Bytes
    size = random.rand(8) == 0 ? 32_768 + random.rand(-2..9_000) : size_up_to(random, Math.min(profile.max_bytes, 20_000))
    case random.rand(3)
    when 0
      return Bytes.empty if input.empty?
      size = Math.min(size, input.size)
      input[random.rand(input.size - size + 1), size].dup
    when 1 then text(random, size)
    else        random.random_bytes(size)
    end
  end

  def self.header_for(random : Random) : Mica::Gzip::Header
    extra_field = random.rand(3) == 0 ? random.random_bytes(random.rand(40)) : nil
    file_name = random.rand(2) == 0 ? Bytes.new(random.rand(24)) { random.rand(1..255).to_u8 } : nil
    comment = random.rand(3) == 0 ? Bytes.new(random.rand(60)) { random.rand(1..255).to_u8 } : nil
    Mica::Gzip::Header.new(modification_time: random.rand(UInt32), extra_flags: random.rand(UInt8),
      operating_system: random.rand(UInt8), is_text: random.rand(2) == 0, extra_field: extra_field, file_name: file_name,
      comment: comment)
  end

  # Builds the case of *seed* and *iteration*.
  def self.case_for(seed : Int64, iteration : Int32, profile : Profile = Profile::FULL) : Case
    random = DeflateFuzz.random_for(seed, iteration, 7)
    family = Family.values.sample(random)
    # Boundary sizes are the largest inputs: one case in twelve.
    family = Family::Text if family.window_boundary? && random.rand(2) == 0
    input = input_of(random, family, profile)
    format = Format.values.sample(random)
    level = random.rand(10)
    dictionary = format.zlib? && random.rand(4) == 0 ? dictionary_for(random, input, profile) : nil
    header = format.gzip? && random.rand(3) == 0 ? header_for(random) : nil
    chunking = Chunking.values.sample(random)
    chunking = Chunking::RandomPieces if chunking.byte_by_byte? && input.size > 8_192
    flush_one_in = random.rand(2) == 0 ? 0 : random.rand(1..40)
    Case.new(family, format, level, input, dictionary, header, chunking, flush_one_in, random.rand(UInt64))
  end

  def self.encode_at_once(kase : Case) : Bytes
    case kase.format
    in .raw?  then Mica::Deflate.encode(kase.input, level: kase.level)
    in .zlib? then Mica::Zlib.encode(kase.input, level: kase.level, dictionary: kase.dictionary)
    in .gzip? then Mica::Gzip.encode(kase.input, level: kase.level, header: kase.header)
    end
  end

  def self.writer_for(kase : Case, io : IO) : Mica::Deflate::StreamWriter
    case kase.format
    in .raw?  then Mica::Deflate::Writer.new(io, level: kase.level)
    in .zlib? then Mica::Zlib::Writer.new(io, level: kase.level, dictionary: kase.dictionary)
    in .gzip? then Mica::Gzip::Writer.new(io, level: kase.level, header: kase.header)
    end
  end

  # Encodes through the Writer the way the case says, flushing (one flush
  # in four a full flush) after a piece with probability 1 in
  # `flush_one_in`.
  def self.encode_streamed(kase : Case) : Bytes
    random = Random::PCG32.new(kase.writer_seed)
    io = IO::Memory.new
    writer = writer_for(kase, io)
    input = kase.input
    offset = 0
    while offset < input.size
      size = case kase.chunking
             in .one_write?     then input.size
             in .byte_by_byte?  then 1
             in .random_pieces? then 1 + size_up_to(random, 20_000)
             in .large_pieces?  then 65_536
             end
      size = Math.min(size, input.size - offset)
      writer.write(input[offset, size])
      offset += size
      if kase.flush_one_in > 0 && random.rand(kase.flush_one_in) == 0
        random.rand(4) == 0 ? writer.full_flush : writer.flush
      end
    end
    writer.flush if kase.flush_one_in == 1
    writer.close
    io.to_slice
  end

  def self.decode_with_mica(kase : Case, stream : Bytes) : Bytes
    case kase.format
    in .raw?  then Mica::Deflate.decode(stream, limits: LIMITS, timeout: nil)
    in .zlib? then Mica::Zlib.decode(stream, limits: LIMITS, timeout: nil, dictionary: kase.dictionary)
    in .gzip? then Mica::Gzip.decode(stream, limits: LIMITS, timeout: nil)
    end
  end

  # The most bytes a one-shot stream may take: the input, 5 bytes for
  # every block (a block is never larger than its stored form) and the
  # container.
  def self.size_bound(kase : Case) : Int64
    size = kase.input.size.to_i64
    bound = size + 5 * (size // 16_383 + size // 65_535 + 2)
    bound += 6 + (kase.dictionary ? 4 : 0) if kase.format.zlib?
    if kase.format.gzip?
      bound += 18
      if header = kase.header
        bound += field_bytes(header.extra_field, 2) + field_bytes(header.file_name, 1) + field_bytes(header.comment, 1)
      end
    end
    bound
  end

  private def self.field_bytes(field : Bytes?, framing : Int32) : Int32
    field ? field.size + framing : 0
  end

  # Returns what is wrong with *stream* as an encoding of the case's
  # input, or nil: the system zlib and Mica must both decode it to the input.
  def self.failure_of(kase : Case, label : String, stream : Bytes) : String?
    by_zlib = DeflateOracle.decode(kase.format, stream, kase.dictionary)
    return "#{label}: zlib rejects the stream (#{by_zlib.rejection}: #{by_zlib.detail})" unless by_zlib.accepted?
    return "#{label}: zlib decodes #{by_zlib.output.size} bytes that are not the input" unless by_zlib.output == kase.input
    by_mica = decode_with_mica(kase, stream)
    return "#{label}: Mica decodes #{by_mica.size} bytes that are not the input" unless by_mica == kase.input
    nil
  rescue error : Mica::Error
    "#{label}: Mica rejects the stream (#{error.class}: #{error.message})"
  end

  # Runs one case and returns its failures (empty when it passes).
  def self.failures_of(kase : Case) : Array(String)
    list_of_failures = [] of String
    begin
      at_once = encode_at_once(kase)
      if failure = failure_of(kase, "one-shot", at_once)
        list_of_failures << failure
      end
      if at_once.size > size_bound(kase)
        list_of_failures << "one-shot: #{at_once.size} bytes pass the bound of #{size_bound(kase)}"
      end
      list_of_failures << "one-shot: a second encode gives other bytes" unless encode_at_once(kase) == at_once
      if failure = failure_of(kase, "writer", encode_streamed(kase))
        list_of_failures << failure
      end
    rescue error : Exception
      # A harness-level catch: any exception out of the encoder is a finding.
      list_of_failures << "crash: #{error.class}: #{error.message}"
    end
    list_of_failures
  end

  # What a run did.
  class Report
    getter cases = 0
    getter streams = 0
    getter input_bytes = 0_i64
    getter by_family = Hash(Family, Int32).new(0)
    getter by_format = Hash(Format, Int32).new(0)
    getter by_level = Hash(Int32, Int32).new(0)
    getter by_chunking = Hash(Chunking, Int32).new(0)
    getter with_dictionary = 0
    getter with_header = 0
    getter with_flushes = 0
    getter list_of_failures = [] of String

    def record(id : String, kase : Case, failures : Array(String)) : Nil
      @cases += 1
      @streams += 2
      @input_bytes += kase.input.size
      @by_family[kase.family] += 1
      @by_format[kase.format] += 1
      @by_level[kase.level] += 1
      @by_chunking[kase.chunking] += 1
      @with_dictionary += 1 if kase.dictionary
      @with_header += 1 if kase.header
      @with_flushes += 1 if kase.flush_one_in > 0
      failures.each { |failure| @list_of_failures << "#{id} (#{kase}): #{failure}" }
    end

    def clean? : Bool
      @list_of_failures.empty?
    end

    def to_s(io : IO) : Nil
      io << "cases=" << @cases << " streams=" << @streams << " failures=" << @list_of_failures.size
      io << " input_bytes=" << @input_bytes
    end

    def coverage : String
      String.build do |io|
        io << "families: " << Family.values.join(" ") { |family| "#{family}=#{@by_family[family]}" }
        io << "; containers: " << Format.values.join(" ") { |format| "#{format}=#{@by_format[format]}" }
        io << "; levels: " << (0..9).join(" ") { |level| "#{level}=#{@by_level[level]}" }
        io << "; chunking: " << Chunking.values.join(" ") { |chunking| "#{chunking}=#{@by_chunking[chunking]}" }
        io << "; dictionary=" << @with_dictionary << " gzip_header=" << @with_header << " flushes=" << @with_flushes
      end
    end
  end

  # Runs *iterations* cases of *seed*, starting at iteration *first*.
  def self.run(seed : Int64, iterations : Int32, first : Int32 = 0, profile : Profile = Profile::FULL) : Report
    report = Report.new
    iterations.times do |offset|
      iteration = first + offset
      kase = case_for(seed, iteration, profile)
      report.record("#{seed}:#{iteration}", kase, failures_of(kase))
    end
    report
  end
end
