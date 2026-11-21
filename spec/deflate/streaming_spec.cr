require "./support/bit_writer"
# The vector specs register their vectors when they load; this file replays
# all of them through the Readers.
require "./inflate_spec"
require "./zlib_spec"
require "./gzip_spec"
require "./infcover_spec"

# Specs for the streaming Readers and for the API contract shared by the
# three formats: every conformance vector must give the same output, or
# the same error at the same input offset, through a Reader as through the
# one-shot decode, however the input is chunked and however small the
# reads are; plus the Reader's IO behavior, the required arguments, the
# limit presets and each decode limit.

# The arguments named limits or timeout of the methods called *name* on
# *type* (class methods when *class_method*), as {method, argument, has a
# default} tuples, read from the method signatures at compile time.
private macro required_arguments_of(type, name, class_method)
  {% methods = class_method ? type.resolve.class.methods : type.resolve.methods %}
  [
    {% for method in methods.select { |candidate| candidate.name == name } %}
      {% for argument in method.args.select { |candidate| candidate.name == "limits" || candidate.name == "timeout" } %}
        { {{ type.stringify + (class_method ? "." : "#") + name }}, {{ argument.name.stringify }}, {{ !argument.default_value.is_a?(Nop) }} },
      {% end %}
    {% end %}
  ] of {String, String, Bool}
end

# A fixed-block DEFLATE stream of *count* zero bytes: one literal and
# back references of up to 258 bytes at distance 1 (13 bits each).
private def zeros_stream(count : Int32) : DeflateConformance::DeflateWriter
  DeflateConformance.deflate do |deflate|
    deflate.fixed(final: true) do |block|
      block.literal(0)
      remaining = count - 1
      while remaining > 0
        # A reference is at least 3 bytes; leave 3 for the last one.
        length = remaining > 261 ? 258 : (remaining > 258 ? remaining - 3 : remaining)
        block.match(length, 1)
        remaining -= length
      end
    end
  end
end

private def gzip_of(content : String, **options) : Bytes
  DeflateConformance.gzip_member(DeflateConformance.deflate(&.fixed(final: true, &.literals(content))).to_slice, content.to_slice, **options)
end

private def limit_error(& : -> Bytes) : Mica::Deflate::DecodeLimitError
  expect_raises(Mica::Deflate::DecodeLimitError) { yield }
end

private LIMITS = DeflateConformance::LIMITS

describe "Mica::Deflate streaming" do
  describe "every conformance vector through a Reader" do
    DeflateConformance::LIST_OF_VECTORS.each_with_index do |vector, index|
      it_satisfies({"DEFLATE-API-streaming-identical", "DEFLATE-API-one-byte-reads"}, "#{vector.format.to_s.downcase} vector #{index}: #{vector.label}") do
        # The vector's own example checks the one-shot outcome against what
        # the vector requires; this one checks the Reader against the one-shot.
        one_shot = DeflateConformance.decode_one_shot(vector)
        DeflateConformance::LIST_OF_CHUNK_SIZES.each do |chunk_size|
          streamed = DeflateConformance.decode_streaming(vector, chunk_size, 4_096)
          fail "input chunks of #{chunk_size}: one-shot gave #{one_shot}, the Reader gave #{streamed}; input: #{DeflateConformance.hex_of(vector.input)}" unless streamed == one_shot
        end
        # One output byte per read, over input that arrives one byte at a
        # time and over input that arrives all at once.
        {1, 4_096}.each do |chunk_size|
          streamed = DeflateConformance.decode_streaming(vector, chunk_size, 1)
          fail "1-byte reads over input chunks of #{chunk_size}: one-shot gave #{one_shot}, the Reader gave #{streamed}; input: #{DeflateConformance.hex_of(vector.input)}" unless streamed == one_shot
        end
      end
    end

    it_satisfies "DEFLATE-API-streaming-identical", "replays vectors of all three formats" do
      DeflateConformance::LIST_OF_VECTORS.count(&.format.raw?).should be > 150
      DeflateConformance::LIST_OF_VECTORS.count(&.format.zlib?).should be > 80
      DeflateConformance::LIST_OF_VECTORS.count(&.format.gzip?).should be > 100
    end

    it_satisfies "DEFLATE-API-streaming-identical", "gives the output before an error that the one-shot decode cannot return" do
      # 600 bytes of output, then a reserved block type.
      data = DeflateConformance.sample_bytes(600)
      input = DeflateConformance.deflate(&.stored(data).block_header(3, final: true)).to_slice
      DeflateConformance::LIST_OF_CHUNK_SIZES.each do |chunk_size|
        reader = Mica::Deflate::Reader.new(TrickleIO.new(input, chunk_size), limits: LIMITS, timeout: nil)
        output = IO::Memory.new
        expect_raises(Mica::Deflate::MalformedStreamError) { IO.copy(reader, output) }
        output.to_slice.should eq(data[0, output.size])
      end
    end

    it_satisfies "DEFLATE-API-streaming-identical", "decodes input that arrives in chunks of every size from 1 to 64" do
      stream = DeflateConformance.deflate do |deflate|
        deflate.stored(DeflateConformance.sample_bytes(700))
        deflate.fixed(&.literals("fixed block").match(258, 300).match(40, 11))
        deflate.dynamic(Array.new(286) { |symbol| {97, 98, 256, 257}.includes?(symbol) ? 2 : 0 }, [1, 1], final: true, &.literals("abba").match(3, 1).match(3, 2))
      end
      list_of_inputs = {
        DeflateConformance::Format::Raw  => stream.to_slice,
        DeflateConformance::Format::Zlib => DeflateConformance.zlib_stream(stream.to_slice, stream.expected),
        DeflateConformance::Format::Gzip => DeflateConformance.join(
          DeflateConformance.gzip_member(stream.to_slice, stream.expected, header_crc: true, file_name: "name".to_slice),
          DeflateConformance.gzip_member(stream.to_slice, stream.expected, extra: Bytes[1, 2, 3], comment: "comment".to_slice)),
      }
      list_of_inputs.each do |format, input|
        expected = format.gzip? ? DeflateConformance.join(stream.expected, stream.expected) : stream.expected
        1.upto(64) do |chunk_size|
          reader = DeflateConformance.reader(format, TrickleIO.new(input, chunk_size))
          reader.getb_to_end.should eq(expected)
        end
      end
    end

    it_satisfies "DEFLATE-API-one-byte-reads", "reads with slices of every size from 1 to 300" do
      stream = DeflateConformance.deflate do |deflate|
        deflate.stored(DeflateConformance.sample_bytes(5_000))
        deflate.fixed(final: true, &.match(258, 5_000).match(258, 1).match(100, 4_000))
      end
      1.upto(300) do |read_size|
        reader = Mica::Deflate::Reader.new(TrickleIO.new(stream.to_slice, 7), limits: LIMITS, timeout: nil)
        output = IO::Memory.new
        buffer = Bytes.new(read_size)
        loop do
          count = reader.read(buffer)
          break if count == 0
          output.write(buffer[0, count])
        end
        output.to_slice.should eq(stream.expected)
      end
    end
  end

  describe "the Reader as an IO" do
    it_satisfies "DEFLATE-API-reader-io", "is an IO whose read returns 0 at the end of the stream, again and again" do
      input = DeflateConformance.deflate(&.fixed(final: true, &.literals("end"))).to_slice
      reader = Mica::Deflate::Reader.new(IO::Memory.new(input), limits: LIMITS, timeout: nil)
      reader.should be_a(IO)
      reader.gets_to_end.should eq("end")
      buffer = Bytes.new(8)
      3.times { reader.read(buffer).should eq(0) }
      reader.read_byte.should be_nil
    end

    it_satisfies "DEFLATE-API-reader-io", "returns 0 for an empty slice without touching the stream" do
      input = DeflateConformance.deflate(&.fixed(final: true, &.literals("abc"))).to_slice
      reader = Mica::Deflate::Reader.new(IO::Memory.new(input), limits: LIMITS, timeout: nil)
      reader.read(Bytes.empty).should eq(0)
      reader.gets_to_end.should eq("abc")
    end

    it_satisfies "DEFLATE-API-reader-io", "supports the IO reading methods" do
      text = "line one\nline two\nline three"
      input = DeflateConformance.zlib_stream(DeflateConformance.deflate(&.fixed(final: true, &.literals(text))).to_slice, text.to_slice)
      reader = Mica::Zlib::Reader.new(TrickleIO.new(input, 3), limits: LIMITS, timeout: nil)
      reader.gets.should eq("line one")
      reader.read_char.should eq('l')
      reader.read_string(3).should eq("ine")
      buffer = Bytes.new(4)
      reader.read_fully(buffer)
      String.new(buffer).should eq(" two")
      reader.read_line.should eq("")
      reader.gets_to_end.should eq("line three")
      reader.gets.should be_nil
    end

    it_satisfies "DEFLATE-API-reader-io", "refuses writes" do
      [Mica::Deflate::Reader.new(IO::Memory.new, limits: LIMITS, timeout: nil),
       Mica::Zlib::Reader.new(IO::Memory.new, limits: LIMITS, timeout: nil),
       Mica::Gzip::Reader.new(IO::Memory.new, limits: LIMITS, timeout: nil)].each do |reader|
        expect_raises(IO::Error) { reader.write(Bytes[1]) }
      end
    end

    it_satisfies "DEFLATE-API-reader-io", "leaves its source open when closed without sync_close" do
      input = DeflateConformance.deflate(&.fixed(final: true, &.literals("abc"))).to_slice
      source = IO::Memory.new(input)
      reader = Mica::Deflate::Reader.new(source, limits: LIMITS, timeout: nil)
      reader.gets_to_end.should eq("abc")
      reader.close
      reader.closed?.should be_true
      source.closed?.should be_false
      expect_raises(IO::Error) { reader.read(Bytes.new(1)) }
      reader.close
    end

    it_satisfies "DEFLATE-API-reader-io", "closes its source with sync_close, for all three formats" do
      raw = DeflateConformance.deflate(&.fixed(final: true, &.literals("abc"))).to_slice
      source = IO::Memory.new(raw)
      Mica::Deflate::Reader.new(source, limits: LIMITS, timeout: nil, sync_close: true).close
      source.closed?.should be_true

      source = IO::Memory.new(DeflateConformance.zlib_stream(raw, "abc".to_slice))
      Mica::Zlib::Reader.new(source, limits: LIMITS, timeout: nil, sync_close: true).close
      source.closed?.should be_true

      source = IO::Memory.new(DeflateConformance.gzip_member(raw, "abc".to_slice))
      Mica::Gzip::Reader.new(source, limits: LIMITS, timeout: nil, sync_close: true).close
      source.closed?.should be_true
    end

    it_satisfies "DEFLATE-API-reader-io", "raises a truncation error from read, not an end of file, when the source ends early" do
      input = DeflateConformance.deflate(&.stored("abcdef".to_slice, final: true)).to_slice[0, 8]
      reader = Mica::Deflate::Reader.new(IO::Memory.new(input), limits: LIMITS, timeout: nil)
      error = expect_raises(Mica::Deflate::TruncatedStreamError) { reader.getb_to_end }
      error.byte_offset.should eq(8)
    end
  end

  describe "required arguments" do
    it_satisfies "DEFLATE-API-required-limits", "gives limits and timeout no default on any decode entry point" do
      list_of_arguments = required_arguments_of(Mica::Deflate, "decode", true) +
                          required_arguments_of(Mica::Zlib, "decode", true) +
                          required_arguments_of(Mica::Gzip, "decode", true) +
                          required_arguments_of(Mica::Deflate::Reader, "initialize", false) +
                          required_arguments_of(Mica::Zlib::Reader, "initialize", false) +
                          required_arguments_of(Mica::Gzip::Reader, "initialize", false)
      list_of_arguments.map { |entry| "#{entry[0]} #{entry[1]}" }.sort!.should eq([
        "Mica::Deflate.decode limits", "Mica::Deflate.decode timeout",
        "Mica::Deflate::Reader#initialize limits", "Mica::Deflate::Reader#initialize timeout",
        "Mica::Gzip.decode limits", "Mica::Gzip.decode timeout",
        "Mica::Gzip::Reader#initialize limits", "Mica::Gzip::Reader#initialize timeout",
        "Mica::Zlib.decode limits", "Mica::Zlib.decode timeout",
        "Mica::Zlib::Reader#initialize limits", "Mica::Zlib::Reader#initialize timeout",
      ])
      list_of_arguments.select { |entry| entry[2] }.should be_empty
    end

    it_satisfies "DEFLATE-API-limit-presets", "has the four presets, each within the 32 KiB window" do
      list_of_presets = [
        Mica::Deflate::DecodeLimits::REQUEST_BODY, Mica::Deflate::DecodeLimits::HTTP_CLIENT_RESPONSE,
        Mica::Deflate::DecodeLimits::WEBSOCKET_MESSAGE, Mica::Deflate::DecodeLimits::TRUSTED_ASSET,
      ]
      list_of_presets.each do |preset|
        preset.max_output_bytes.should be > 0
        preset.max_ratio.should be > 0
        (1..32_768).should contain(preset.max_window_bytes)
        preset.max_members.should be > 0
        preset.max_metadata_bytes.should be >= 0
      end
    end

    it_satisfies "DEFLATE-API-limit-presets", "starts custom limits from REQUEST_BODY and changes only what is given" do
      request_body = Mica::Deflate::DecodeLimits::REQUEST_BODY
      Mica::Deflate::DecodeLimits.custom.should eq(request_body)
      custom = Mica::Deflate::DecodeLimits.custom(max_members: 3, max_output_bytes: 1_234_i64)
      custom.max_members.should eq(3)
      custom.max_output_bytes.should eq(1_234)
      custom.max_ratio.should eq(request_body.max_ratio)
      custom.max_window_bytes.should eq(request_body.max_window_bytes)
      custom.max_metadata_bytes.should eq(request_body.max_metadata_bytes)
      custom.work_per_unit.should eq(request_body.work_per_unit)
      custom.base_work.should eq(request_body.base_work)
      custom.work_ceiling.should eq(request_body.work_ceiling)
    end

    it_satisfies "DEFLATE-API-limit-presets", "refuses a window above 32,768 bytes" do
      expect_raises(ArgumentError) { Mica::Deflate::DecodeLimits.custom(max_window_bytes: 32_769) }
      Mica::Deflate::DecodeLimits.custom(max_window_bytes: 32_768).max_window_bytes.should eq(32_768)
    end
  end

  describe "decode limits" do
    it_satisfies "DEFLATE-LIMIT-max-output-bytes", "allows output of exactly max_output_bytes and refuses one byte more, in each format" do
      stream = zeros_stream(1_000)
      exact = Mica::Deflate::DecodeLimits.custom(max_output_bytes: 1_000_i64)
      short = Mica::Deflate::DecodeLimits.custom(max_output_bytes: 999_i64)
      zlib = DeflateConformance.zlib_stream(stream.to_slice, stream.expected)
      gzip = DeflateConformance.gzip_member(stream.to_slice, stream.expected)

      Mica::Deflate.decode(stream.to_slice, limits: exact, timeout: nil).size.should eq(1_000)
      Mica::Zlib.decode(zlib, limits: exact, timeout: nil).size.should eq(1_000)
      Mica::Gzip.decode(gzip, limits: exact, timeout: nil).size.should eq(1_000)

      error = limit_error { Mica::Deflate.decode(stream.to_slice, limits: short, timeout: nil) }
      error.limit.should eq("max_output_bytes")
      error.should be_a(Mica::LimitExceededError)
      error.should be_a(Mica::Error)
      limit_error { Mica::Zlib.decode(zlib, limits: short, timeout: nil) }.limit.should eq("max_output_bytes")
      limit_error { Mica::Gzip.decode(gzip, limits: short, timeout: nil) }.limit.should eq("max_output_bytes")
    end

    it_satisfies "DEFLATE-LIMIT-max-output-bytes", "counts the output of every gzip member together" do
      three_members = DeflateConformance.join(gzip_of("a" * 400), gzip_of("b" * 400), gzip_of("c" * 400))
      Mica::Gzip.decode(three_members, limits: Mica::Deflate::DecodeLimits.custom(max_output_bytes: 1_200_i64), timeout: nil).size.should eq(1_200)
      error = limit_error { Mica::Gzip.decode(three_members, limits: Mica::Deflate::DecodeLimits.custom(max_output_bytes: 1_199_i64), timeout: nil) }
      error.limit.should eq("max_output_bytes")
    end

    it_satisfies "DEFLATE-LIMIT-max-output-bytes", "stops a Reader at max_output_bytes however the input is chunked" do
      stream = zeros_stream(100_000)
      short = Mica::Deflate::DecodeLimits.custom(max_output_bytes: 50_000_i64)
      DeflateConformance::LIST_OF_CHUNK_SIZES.each do |chunk_size|
        reader = Mica::Deflate::Reader.new(TrickleIO.new(stream.to_slice, chunk_size), limits: short, timeout: nil)
        output = IO::Memory.new
        error = expect_raises(Mica::Deflate::DecodeLimitError) { IO.copy(reader, output) }
        error.limit.should eq("max_output_bytes")
        output.size.should be <= 50_000
      end
    end

    it_satisfies "DEFLATE-LIMIT-max-ratio", "refuses output past 1 MiB that outgrows max_ratio times the input" do
      # 2 MiB of zeros from about 13 KiB of input: a ratio near 158.
      stream = zeros_stream(2_097_152)
      loose = Mica::Deflate::DecodeLimits.custom(max_ratio: 200_i64)
      tight = Mica::Deflate::DecodeLimits.custom(max_ratio: 100_i64)
      Mica::Deflate.decode(stream.to_slice, limits: loose, timeout: nil).size.should eq(2_097_152)
      limit_error { Mica::Deflate.decode(stream.to_slice, limits: tight, timeout: nil) }.limit.should eq("max_ratio")
      reader = Mica::Deflate::Reader.new(TrickleIO.new(stream.to_slice, 4_096), limits: tight, timeout: nil)
      expect_raises(Mica::Deflate::DecodeLimitError) { IO.copy(reader, IO::Memory.new) }.limit.should eq("max_ratio")
    end

    it_satisfies "DEFLATE-LIMIT-max-ratio", "leaves output under 1 MiB alone whatever its ratio" do
      stream = zeros_stream(1_000_000)
      tight = Mica::Deflate::DecodeLimits.custom(max_ratio: 2_i64)
      Mica::Deflate.decode(stream.to_slice, limits: tight, timeout: nil).size.should eq(1_000_000)
    end

    it_satisfies "DEFLATE-LIMIT-max-window-bytes", "allows a back reference of exactly max_window_bytes and refuses one byte farther" do
      narrow = Mica::Deflate::DecodeLimits.custom(max_window_bytes: 256)
      inside = DeflateConformance.deflate do |deflate|
        deflate.stored(DeflateConformance.sample_bytes(400))
        deflate.fixed(final: true, &.match(3, 256))
      end
      outside = DeflateConformance.deflate do |deflate|
        deflate.stored(DeflateConformance.sample_bytes(400))
        deflate.fixed(final: true, &.match(3, 257))
      end
      Mica::Deflate.decode(inside.to_slice, limits: narrow, timeout: nil).should eq(inside.expected)
      limit_error { Mica::Deflate.decode(outside.to_slice, limits: narrow, timeout: nil) }.limit.should eq("max_window_bytes")
      Mica::Deflate.decode(outside.to_slice, limits: LIMITS, timeout: nil).should eq(outside.expected)
      gzip = DeflateConformance.gzip_member(outside.to_slice, outside.expected)
      limit_error { Mica::Gzip.decode(gzip, limits: narrow, timeout: nil) }.limit.should eq("max_window_bytes")
    end

    it_satisfies "DEFLATE-LIMIT-max-window-bytes", "refuses a zlib header that declares a window above max_window_bytes" do
      stream = DeflateConformance.deflate(&.fixed(final: true, &.literals("abc")))
      narrow = Mica::Deflate::DecodeLimits.custom(max_window_bytes: 1_024)
      # CINFO 2 declares 1,024 bytes; CINFO 3 declares 2,048.
      Mica::Zlib.decode(DeflateConformance.zlib_stream(stream.to_slice, stream.expected, compression_info: 2), limits: narrow, timeout: nil).should eq("abc".to_slice)
      error = limit_error { Mica::Zlib.decode(DeflateConformance.zlib_stream(stream.to_slice, stream.expected, compression_info: 3), limits: narrow, timeout: nil) }
      error.limit.should eq("max_window_bytes")
    end

    it_satisfies "DEFLATE-LIMIT-max-members", "allows max_members gzip members and refuses one more" do
      three_members = DeflateConformance.join(gzip_of("one "), gzip_of("two "), gzip_of("three"))
      Mica::Gzip.decode(three_members, limits: Mica::Deflate::DecodeLimits.custom(max_members: 3), timeout: nil).should eq("one two three".to_slice)
      error = limit_error { Mica::Gzip.decode(three_members, limits: Mica::Deflate::DecodeLimits.custom(max_members: 2), timeout: nil) }
      error.limit.should eq("max_members")
      reader = Mica::Gzip::Reader.new(TrickleIO.new(three_members, 1), limits: Mica::Deflate::DecodeLimits.custom(max_members: 1), timeout: nil)
      expect_raises(Mica::Deflate::DecodeLimitError) { IO.copy(reader, IO::Memory.new) }.limit.should eq("max_members")
    end

    it_satisfies "DEFLATE-LIMIT-max-metadata-bytes", "refuses a gzip member whose extra field, name and comment pass max_metadata_bytes" do
      small = Mica::Deflate::DecodeLimits.custom(max_metadata_bytes: 100)
      Mica::Gzip.decode(gzip_of("ok", extra: Bytes.new(20), file_name: Bytes.new(20, 0x61_u8), comment: Bytes.new(20, 0x62_u8)), limits: small, timeout: nil).should eq("ok".to_slice)
      {
        gzip_of("no", extra: Bytes.new(200)),
        gzip_of("no", file_name: Bytes.new(200, 0x61_u8)),
        gzip_of("no", comment: Bytes.new(200, 0x62_u8)),
        gzip_of("no", extra: Bytes.new(40), file_name: Bytes.new(40, 0x61_u8), comment: Bytes.new(40, 0x62_u8)),
      }.each do |input|
        limit_error { Mica::Gzip.decode(input, limits: small, timeout: nil) }.limit.should eq("max_metadata_bytes")
      end
    end

    it_satisfies "DEFLATE-LIMIT-max-metadata-bytes", "counts each member's metadata on its own" do
      small = Mica::Deflate::DecodeLimits.custom(max_metadata_bytes: 100)
      two_members = DeflateConformance.join(gzip_of("a", file_name: Bytes.new(70, 0x61_u8)), gzip_of("b", comment: Bytes.new(70, 0x62_u8)))
      Mica::Gzip.decode(two_members, limits: small, timeout: nil).should eq("ab".to_slice)
    end

    it_satisfies "DEFLATE-LIMIT-max-metadata-bytes", "refuses a name with no end before reading more than the limit allows" do
      small = Mica::Deflate::DecodeLimits.custom(max_metadata_bytes: 100)
      # FNAME set, then a megabyte of name bytes and no terminating zero.
      input = DeflateConformance.join(Bytes[0x1f, 0x8b, 8, 0x08, 0, 0, 0, 0, 0, 255], Bytes.new(1_048_576, 0x61_u8))
      limit_error { Mica::Gzip.decode(input, limits: small, timeout: nil) }.limit.should eq("max_metadata_bytes")
    end

    it_satisfies "DEFLATE-LIMIT-work-budget", "raises WorkBudgetExceededError when the work allowance runs out" do
      stream = zeros_stream(200_000)
      starved = Mica::Deflate::DecodeLimits.custom(work_per_unit: 0_i64, base_work: 1_000_i64)
      error = expect_raises(Mica::WorkBudgetExceededError) { Mica::Deflate.decode(stream.to_slice, limits: starved, timeout: nil) }
      error.should be_a(Mica::LimitExceededError)
      capped = Mica::Deflate::DecodeLimits.custom(work_ceiling: 1_000_i64)
      expect_raises(Mica::WorkBudgetExceededError) { Mica::Gzip.decode(DeflateConformance.gzip_member(stream.to_slice, stream.expected), limits: capped, timeout: nil) }
      reader = Mica::Deflate::Reader.new(TrickleIO.new(stream.to_slice, 7), limits: starved, timeout: nil)
      expect_raises(Mica::WorkBudgetExceededError) { IO.copy(reader, IO::Memory.new) }
    end

    it_satisfies "DEFLATE-LIMIT-work-budget", "decodes under the REQUEST_BODY work allowance" do
      stream = zeros_stream(200_000)
      Mica::Deflate.decode(stream.to_slice, limits: Mica::Deflate::DecodeLimits::REQUEST_BODY, timeout: nil).size.should eq(200_000)
    end

    it_satisfies "DEFLATE-LIMIT-deadline", "raises DeadlineExceededError when the timeout has passed" do
      stream = zeros_stream(200_000)
      error = expect_raises(Mica::DeadlineExceededError) { Mica::Deflate.decode(stream.to_slice, limits: LIMITS, timeout: Time::Span.zero) }
      error.should be_a(Mica::LimitExceededError)
      expect_raises(Mica::DeadlineExceededError) do
        Mica::Zlib.decode(DeflateConformance.zlib_stream(stream.to_slice, stream.expected), limits: LIMITS, timeout: Time::Span.zero)
      end
      expect_raises(Mica::DeadlineExceededError) do
        Mica::Gzip.decode(DeflateConformance.gzip_member(stream.to_slice, stream.expected), limits: LIMITS, timeout: Time::Span.zero)
      end
      expect_raises(Mica::DeadlineExceededError) do
        reader = Mica::Deflate::Reader.new(TrickleIO.new(stream.to_slice, 4_096), limits: LIMITS, timeout: Time::Span.zero)
        IO.copy(reader, IO::Memory.new)
      end
    end

    it_satisfies "DEFLATE-LIMIT-deadline", "decodes within a generous timeout" do
      stream = zeros_stream(200_000)
      Mica::Deflate.decode(stream.to_slice, limits: LIMITS, timeout: 30.seconds).size.should eq(200_000)
    end
  end
end
