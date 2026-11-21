require "../spec_helper"
require "./fixtures/corpus"

# Decompression attacks and malformed streams against Mica::Deflate,
# Mica::Zlib and Mica::Gzip (recipes in fixtures/corpus.cr, small cases as
# files under fixtures/attacks/ and fixtures/malformed/).
#
# Every attack must be stopped by the exact typed error, in the one-shot
# decode and in the Reader, within bounded memory. The one-shot decode
# grows its output by doubling, capped at max_output_bytes, so the bytes it
# allocates stay under twice max_output_bytes plus `MEMORY_SLACK`. The
# Reader's buffers are fixed (160 KiB of output, 64 KiB of input), so it
# allocates under `MEMORY_SLACK` whatever the limits, and it never hands
# back more than max_output_bytes. Every malformed
# stream must be rejected with its `MalformedStreamError` class by Mica
# and rejected by the system zlib (fuzz/deflate_oracle.cr).

private MIB = 1_048_576_i64
# What a decode may allocate besides its output: the Reader's fixed
# buffers (window, two runs of output, input), the Huffman tables and the
# error it raises.
private MEMORY_SLACK = 524_288_i64

private alias Limits = Mica::Deflate::DecodeLimits

private def attack(format : DeflateOracle::Format, bytes : Bytes, dictionary : Bytes? = nil) : DeflateFuzz::Case
  DeflateFuzz::Case.new(DeflateFuzz::Family::Structured, format, bytes, dictionary, false)
end

# What one decode did: the error it raised (nil when it finished), the
# bytes it returned or handed back, and the bytes allocated meanwhile.
# *allowed_bytes* is the allocation bound of that way of decoding.
private record Observation, error : Mica::Error?, output_bytes : Int64, allocated_bytes : Int64, allowed_bytes : Int64

private def observe_at_once(kase : DeflateFuzz::Case, limits : Limits, timeout : Time::Span?) : Observation
  before = allocated_bytes_so_far
  outcome = DeflateFuzz.decode_at_once(kase, limits, timeout)
  Observation.new(outcome.error, outcome.output.size.to_i64, allocated_bytes_so_far - before,
    2 * limits.max_output_bytes + MEMORY_SLACK)
end

private def observe_reader(kase : DeflateFuzz::Case, limits : Limits, timeout : Time::Span?, chunk : Int32) : Observation
  source = IO::Memory.new(kase.bytes)
  buffer = Bytes.new(chunk)
  handed_back = 0_i64
  failure = nil
  before = allocated_bytes_so_far
  begin
    reader = DeflateFuzz.reader_for(kase, source, limits, timeout)
    loop do
      count = reader.read(buffer)
      break if count == 0
      handed_back += count
    end
  rescue error : Mica::Error
    failure = error
  end
  Observation.new(failure, handed_back, allocated_bytes_so_far - before, MEMORY_SLACK)
end

# Checks that *kase* is stopped by *error_class* (and, for a
# `DecodeLimitError`, by the limit *limit_name*) both ways, within the
# memory bound.
private def it_is_stopped(kase : DeflateFuzz::Case, limits : Limits, error_class : Mica::Error.class,
                          limit_name : String? = nil, timeout : Time::Span? = nil) : Nil
  list_of_observations = {
    "one-shot"             => observe_at_once(kase, limits, timeout),
    "Reader, 16 KiB reads" => observe_reader(kase, limits, timeout, 16_384),
    "Reader, 1-byte reads" => observe_reader(kase, limits, timeout, 1),
  }
  list_of_observations.each do |label, observation|
    error = observation.error
    {label, error.class}.should eq({label, error_class})
    if limit_name && error.is_a?(Mica::Deflate::DecodeLimitError)
      {label, error.limit}.should eq({label, limit_name})
    end
    {label, observation.output_bytes <= limits.max_output_bytes}.should eq({label, true})
    {label, observation.allocated_bytes < observation.allowed_bytes}.should eq({label, true}),
      "#{label} allocated #{observation.allocated_bytes} bytes; the bound is #{observation.allowed_bytes}"
  end
end

private def attack_file(file_name : String) : DeflateFuzz::Case
  format = DeflateOracle::Format.parse(file_name.split('-').first)
  attack(format, DeflateCorpus.read("attacks", file_name))
end

describe "Mica::Deflate against decompression attacks" do
  describe "1,032:1 streams" do
    ["raw-1032-to-1-16mib.bin", "zlib-1032-to-1-16mib.bin", "gzip-1032-to-1-16mib.bin"].each do |file_name|
      it_satisfies({"DEFLATE-LIMIT-max-output-bytes", "DEFLATE-LIMIT-bounded-memory"}, "stops #{file_name} at max_output_bytes") do
        kase = attack_file(file_name)
        (DeflateCorpus.densest_output_size(DeflateCorpus::SIXTEEN_MIB) / kase.bytes.size).should be > 1_025
        it_is_stopped(kase, Limits.custom(max_output_bytes: 2 * MIB), Mica::Deflate::DecodeLimitError, "max_output_bytes")
      end

      it_satisfies({"DEFLATE-LIMIT-max-ratio", "DEFLATE-LIMIT-bounded-memory"}, "stops #{file_name} at a max_ratio of 1,000") do
        limits = Limits.custom(max_output_bytes: 4 * MIB, max_ratio: 1_000_i64)
        it_is_stopped(attack_file(file_name), limits, Mica::Deflate::DecodeLimitError, "max_ratio")
      end
    end

    it_satisfies "DEFLATE-LIMIT-max-output-bytes", "decodes the 16 MiB stream when the limits allow it, as zlib does" do
      kase = attack_file("zlib-1032-to-1-16mib.bin")
      limits = Limits.custom(max_output_bytes: 16 * MIB)
      output = Mica::Zlib.decode(kase.bytes, limits: limits, timeout: nil)
      output.size.should eq(DeflateCorpus.densest_output_size(DeflateCorpus::SIXTEEN_MIB))
      output.all?(&.zero?).should be_true
      DeflateOracle.decode(kase.format, kase.bytes).output.size.should eq(output.size)
    end
  end

  describe "max_output_bytes" do
    it_satisfies({"DEFLATE-LIMIT-max-output-bytes", "DEFLATE-LIMIT-bounded-memory"}, "stops 8 MiB of zeros at a 1 MiB limit") do
      it_is_stopped(attack_file("zlib-zeros-8mib.bin"), Limits.custom(max_output_bytes: MIB), Mica::Deflate::DecodeLimitError, "max_output_bytes")
    end

    it_satisfies "DEFLATE-LIMIT-max-output-bytes", "allows output of exactly the limit and stops one byte past it" do
      data = Bytes.new(100_000) { |index| (index % 7).to_u8 }
      DeflateOracle::Format.each do |format|
        kase = attack(format, DeflateOracle.compress(data, format))
        exact = Limits.custom(max_output_bytes: data.size.to_i64)
        DeflateFuzz.decode_at_once(kase, exact).output.should eq(data)
        observe_reader(kase, exact, nil, 4_096).error.should be_nil
        it_is_stopped(kase, Limits.custom(max_output_bytes: data.size.to_i64 - 1), Mica::Deflate::DecodeLimitError, "max_output_bytes")
      end
    end

    it_satisfies "DEFLATE-LIMIT-max-output-bytes", "counts the output of every gzip member together" do
      member = DeflateOracle.compress(Bytes.new(300_000), DeflateOracle::Format::Gzip)
      kase = attack(DeflateOracle::Format::Gzip, DeflateFuzz.join(member, member, member, member))
      it_is_stopped(kase, Limits.custom(max_output_bytes: MIB), Mica::Deflate::DecodeLimitError, "max_output_bytes")
    end
  end

  describe "max_ratio" do
    it_satisfies({"DEFLATE-LIMIT-max-ratio", "DEFLATE-LIMIT-bounded-memory"}, "stops 4 MiB of repetitive text at a lowered ratio of 50:1") do
      kase = attack_file("gzip-text-4mib.bin")
      (DeflateCorpus.repetitive_text.size // kase.bytes.size).should be > 50
      limits = Limits.custom(max_output_bytes: 8 * MIB, max_ratio: 50_i64)
      it_is_stopped(kase, limits, Mica::Deflate::DecodeLimitError, "max_ratio")
      DeflateFuzz.decode_at_once(kase, Limits.custom(max_output_bytes: 8 * MIB)).output.should eq(DeflateCorpus.repetitive_text)
    end

    it_satisfies "DEFLATE-LIMIT-max-ratio", "leaves output under 1 MiB alone whatever its ratio" do
      data = Bytes.new(MIB.to_i32)
      kase = attack(DeflateOracle::Format::Zlib, DeflateOracle.compress(data, DeflateOracle::Format::Zlib, level: 9))
      DeflateFuzz.decode_at_once(kase, Limits.custom(max_ratio: 2_i64)).output.size.should eq(data.size)
    end
  end

  describe "max_members" do
    it_satisfies({"DEFLATE-LIMIT-max-members", "DEFLATE-LIMIT-bounded-memory"}, "stops 10,000 empty gzip members at a limit of 100") do
      kase = attack(DeflateOracle::Format::Gzip, DeflateCorpus.empty_gzip_members(10_000))
      it_is_stopped(kase, Limits.custom(max_members: 100), Mica::Deflate::DecodeLimitError, "max_members")
    end

    it_satisfies "DEFLATE-LIMIT-max-members", "allows exactly max_members members" do
      kase = attack(DeflateOracle::Format::Gzip, DeflateCorpus.empty_gzip_members(100))
      DeflateFuzz.decode_at_once(kase, Limits.custom(max_members: 100)).error.should be_nil
      it_is_stopped(kase, Limits.custom(max_members: 99), Mica::Deflate::DecodeLimitError, "max_members")
    end
  end

  describe "max_window_bytes" do
    it_satisfies "DEFLATE-LIMIT-max-window-bytes", "stops a zlib header that declares a 32 KiB window at a 16 KiB limit" do
      kase = attack_file("zlib-declares-32k-window.bin")
      it_is_stopped(kase, Limits.custom(max_window_bytes: 16_384), Mica::Deflate::DecodeLimitError, "max_window_bytes")
      DeflateFuzz.decode_at_once(kase, Limits.custom(max_window_bytes: 32_768)).output.should eq(DeflateCorpus::SAMPLE)
    end

    it_satisfies "DEFLATE-LIMIT-max-window-bytes", "stops a back reference farther than the limit" do
      raw = DeflateCorpus.far_back_reference(30_000)
      DeflateOracle.decode(DeflateOracle::Format::Raw, raw).accepted?.should be_true
      kase = attack(DeflateOracle::Format::Raw, raw)
      it_is_stopped(kase, Limits.custom(max_window_bytes: 16_384), Mica::Deflate::DecodeLimitError, "max_window_bytes")
      DeflateFuzz.decode_at_once(kase, Limits.custom(max_window_bytes: 30_000)).error.should be_nil
      it_is_stopped(kase, Limits.custom(max_window_bytes: 29_999), Mica::Deflate::DecodeLimitError, "max_window_bytes")
    end
  end

  describe "max_metadata_bytes" do
    name = Bytes.new(MIB.to_i32, 'n'.ord.to_u8)
    extra = Bytes.new(65_535, 'x'.ord.to_u8)
    payload = Bytes[0x03, 0x00]

    it_satisfies({"DEFLATE-LIMIT-max-metadata-bytes", "DEFLATE-LIMIT-bounded-memory"}, "stops an oversized FEXTRA") do
      kase = attack(DeflateOracle::Format::Gzip, DeflateFuzz.gzip_member(payload, Bytes.empty, extra: extra))
      it_is_stopped(kase, Limits.custom(max_metadata_bytes: 1_024), Mica::Deflate::DecodeLimitError, "max_metadata_bytes")
    end

    it_satisfies({"DEFLATE-LIMIT-max-metadata-bytes", "DEFLATE-LIMIT-bounded-memory"}, "stops a 1 MiB FNAME") do
      kase = attack(DeflateOracle::Format::Gzip, DeflateFuzz.gzip_member(payload, Bytes.empty, file_name: name))
      it_is_stopped(kase, Limits::REQUEST_BODY, Mica::Deflate::DecodeLimitError, "max_metadata_bytes")
    end

    it_satisfies({"DEFLATE-LIMIT-max-metadata-bytes", "DEFLATE-LIMIT-bounded-memory"}, "stops a 1 MiB FCOMMENT") do
      kase = attack(DeflateOracle::Format::Gzip, DeflateFuzz.gzip_member(payload, Bytes.empty, comment: name))
      it_is_stopped(kase, Limits::REQUEST_BODY, Mica::Deflate::DecodeLimitError, "max_metadata_bytes")
    end

    it_satisfies({"DEFLATE-LIMIT-max-metadata-bytes", "DEFLATE-LIMIT-bounded-memory"}, "stops a file name that never ends") do
      member = DeflateFuzz.gzip_member(Bytes.empty, Bytes.empty, file_name: name, is_terminated: false, trailer_bytes: 0)
      kase = attack(DeflateOracle::Format::Gzip, member)
      it_is_stopped(kase, Limits.custom(max_metadata_bytes: 4_096), Mica::Deflate::DecodeLimitError, "max_metadata_bytes")
    end

    it_satisfies "DEFLATE-LIMIT-max-metadata-bytes", "counts FEXTRA, FNAME and FCOMMENT of one member together, and each member anew" do
      third = Bytes.new(400, 'm'.ord.to_u8)
      member = DeflateFuzz.gzip_member(payload, Bytes.empty, extra: third, file_name: third, comment: third)
      kase = attack(DeflateOracle::Format::Gzip, DeflateFuzz.join(member, member, member))
      it_is_stopped(kase, Limits.custom(max_metadata_bytes: 1_199), Mica::Deflate::DecodeLimitError, "max_metadata_bytes")
      DeflateFuzz.decode_at_once(kase, Limits.custom(max_metadata_bytes: 1_200)).error.should be_nil
      DeflateOracle.decode(kase.format, kase.bytes).accepted?.should be_true
    end
  end

  describe "the work budget" do
    tiny = Limits.custom(work_per_unit: 0_i64, base_work: 1_000_i64)

    it_satisfies({"DEFLATE-LIMIT-work-budget", "DEFLATE-LIMIT-bounded-memory"}, "stops a valid stream under a tiny budget") do
      it_is_stopped(attack_file("gzip-text-4mib.bin"), tiny, Mica::WorkBudgetExceededError)
      it_is_stopped(attack_file("raw-1032-to-1-16mib.bin"), tiny, Mica::WorkBudgetExceededError)
    end

    it_satisfies({"DEFLATE-LIMIT-empty-blocks", "DEFLATE-LIMIT-work-budget"}, "decodes a long run of empty stored blocks within the default budget, and stops it under a tiny one") do
      kase = attack(DeflateOracle::Format::Raw, DeflateCorpus.empty_stored_blocks(200_000))
      outcome = DeflateFuzz.decode_at_once(kase, Limits::REQUEST_BODY)
      outcome.error.should be_nil
      outcome.output.size.should eq(0)
      observe_reader(kase, Limits::REQUEST_BODY, nil, 4_096).error.should be_nil
      it_is_stopped(kase, tiny, Mica::WorkBudgetExceededError)
    end

    it_satisfies({"DEFLATE-LIMIT-empty-blocks", "DEFLATE-LIMIT-work-budget", "DEFLATE-LIMIT-bounded-memory"}, "decodes a long run of empty dynamic blocks, each declaring every code, within the default budget, and stops it under a tiny one") do
      kase = attack(DeflateOracle::Format::Raw, DeflateCorpus.empty_dynamic_blocks(4_000))
      DeflateOracle.decode(kase.format, kase.bytes).accepted?.should be_true
      outcome = DeflateFuzz.decode_at_once(kase, Limits::REQUEST_BODY)
      outcome.error.should be_nil
      outcome.output.size.should eq(0)
      observe_reader(kase, Limits::REQUEST_BODY, nil, 4_096).error.should be_nil
      it_is_stopped(kase, tiny, Mica::WorkBudgetExceededError)
    end

    it_satisfies "DEFLATE-LIMIT-empty-blocks", "decodes a short run of empty dynamic blocks to nothing" do
      kase = attack(DeflateOracle::Format::Raw, DeflateCorpus.empty_dynamic_blocks(200))
      outcome = DeflateFuzz.decode_at_once(kase, Limits::REQUEST_BODY)
      outcome.error.should be_nil
      outcome.output.size.should eq(0)
    end
  end

  describe "the deadline" do
    it_satisfies({"DEFLATE-LIMIT-deadline", "DEFLATE-LIMIT-bounded-memory"}, "stops every container at a zero timeout") do
      ["raw-1032-to-1-16mib.bin", "zlib-1032-to-1-16mib.bin", "gzip-1032-to-1-16mib.bin"].each do |file_name|
        it_is_stopped(attack_file(file_name), Limits::REQUEST_BODY, Mica::DeadlineExceededError, timeout: Time::Span.zero)
      end
    end
  end
end

describe "Mica::Deflate against malformed streams" do
  DeflateCorpus::LIST_OF_MALFORMED.each do |entry|
    it_satisfies entry.requirement_id, "rejects #{entry.file_name} (#{entry.description}) as #{entry.error_class_name.split("::").last}, and zlib rejects it" do
      dictionary_file_name = entry.dictionary_file_name
      dictionary = dictionary_file_name ? DeflateCorpus.read("malformed", dictionary_file_name) : nil
      kase = attack(entry.format, DeflateCorpus.read("malformed", entry.file_name), dictionary)
      oracle = DeflateOracle.decode(kase.format, kase.bytes, dictionary)
      oracle.rejected?.should be_true
      # zlib asks for more input exactly where Mica reports a truncated stream.
      (oracle.rejection == DeflateOracle::Rejection::Truncated).should eq(entry.error_class_name == DeflateCorpus::TRUNCATED)
      at_once = DeflateFuzz.decode_at_once(kase, Limits::REQUEST_BODY).error
      at_once.class.name.should eq(entry.error_class_name)
      [1, 3, 4_096].each do |chunk|
        streamed = observe_reader(kase, Limits::REQUEST_BODY, nil, chunk).error
        streamed.class.name.should eq(entry.error_class_name)
        if at_once.is_a?(Mica::ParseError) && streamed.is_a?(Mica::ParseError)
          streamed.byte_offset.should eq(at_once.byte_offset)
        end
      end
    end
  end

  it_satisfies "DEFLATE-API-truncation", "rejects a stream cut at every byte, as zlib does" do
    data = DeflateCorpus::SAMPLE
    dynamic = DeflateOracle.compress(Bytes.new(700) { |index| (index * index % 13 + 97).to_u8 }, level: 9)
    stored = DeflateOracle.compress(data, level: 0)
    gzip = DeflateFuzz.join(
      DeflateFuzz.gzip_member(dynamic, DeflateOracle.decode(DeflateOracle::Format::Raw, dynamic).output, is_text: true,
        extra: "extra field".to_slice, file_name: "name".to_slice, comment: "comment".to_slice, has_header_crc: true),
      DeflateFuzz.gzip_member(stored, data))
    list_of_streams = [
      attack(DeflateOracle::Format::Raw, dynamic),
      attack(DeflateOracle::Format::Raw, stored),
      attack(DeflateOracle::Format::Raw, DeflateCorpus.sample_raw),
      attack(DeflateOracle::Format::Zlib, DeflateOracle.compress(data, DeflateOracle::Format::Zlib, dictionary: DeflateCorpus::DICTIONARY), DeflateCorpus::DICTIONARY),
      attack(DeflateOracle::Format::Gzip, gzip),
    ]
    list_of_streams.each do |whole|
      whole.bytes.size.times do |size|
        kase = whole.copy_with(bytes: whole.bytes[0, size])
        oracle = DeflateOracle.decode(kase.format, kase.bytes, kase.dictionary)
        at_once = DeflateFuzz.decode_at_once(kase, Limits::REQUEST_BODY)
        streamed = observe_reader(kase, Limits::REQUEST_BODY, nil, 1 + size % 5)
        if oracle.accepted?
          # A gzip prefix that ends between two members is a whole stream.
          {size, at_once.error.class}.should eq({size, Nil})
          {size, streamed.error.class}.should eq({size, Nil})
        else
          {size, oracle.rejection}.should eq({size, DeflateOracle::Rejection::Truncated})
          {size, at_once.error.class}.should eq({size, Mica::Deflate::TruncatedStreamError})
          {size, streamed.error.class}.should eq({size, Mica::Deflate::TruncatedStreamError})
        end
      end
    end
  end

  it_satisfies "DEFLATE-API-trailing-data", "rejects every stream followed by one more byte, as zlib does" do
    data = DeflateCorpus::SAMPLE
    DeflateOracle::Format.each do |format|
      stream = DeflateOracle.compress(data, format)
      [0x00_u8, 0x1F_u8, 0xFF_u8].each do |byte|
        kase = attack(format, DeflateFuzz.join(stream, Bytes[byte]))
        DeflateOracle.decode(format, kase.bytes).rejected?.should be_true
        DeflateFuzz.decode_at_once(kase, Limits::REQUEST_BODY).error.should be_a(Mica::Deflate::MalformedStreamError)
        observe_reader(kase, Limits::REQUEST_BODY, nil, 7).error.should be_a(Mica::Deflate::MalformedStreamError)
      end
    end
  end
end
