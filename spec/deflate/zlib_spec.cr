require "./support/bit_writer"

# Conformance specs for zlib streams (RFC 1950) in Mica::Zlib: the header
# (CMF, FLG, FCHECK, FDICT and DICTID), preset dictionaries and the
# Adler-32 trailer, around hand-built DEFLATE data.

private TEXT = "zlib wraps deflate data".to_slice

# A fixed-block DEFLATE stream of `TEXT`.
private def text_stream : DeflateConformance::DeflateWriter
  DeflateConformance.deflate(&.fixed(final: true, &.literals(TEXT)))
end

private def zlib_of(stream : DeflateConformance::DeflateWriter, **options) : Bytes
  DeflateConformance.zlib_stream(stream.to_slice, stream.expected, **options)
end

describe Mica::Zlib do
  describe "the header (RFC 1950 2.2)" do
    it_decodes_vector({"DEFLATE-1950-2.2-cm", "DEFLATE-1950-2.2-fcheck"}, "decodes a stream with the usual 78 9c header", :zlib, zlib_of(text_stream), TEXT)

    it_decodes_vector "DEFLATE-API-one-shot", "decodes a stream of no data", :zlib,
      zlib_of(DeflateConformance.deflate(&.fixed(final: true) { })), Bytes.empty

    it_decodes_vector "DEFLATE-API-one-shot", "decodes stored, fixed and dynamic blocks inside one stream", :zlib,
      zlib_of(DeflateConformance.deflate do |deflate|
        deflate.stored("stored ".to_slice).fixed(&.literals("fixed ").match(6, 6))
        deflate.dynamic(Array.new(257) { |symbol| symbol == 97 || symbol == 256 ? 1 : 0 }, [0], final: true, &.literals("aaaa"))
      end), "stored fixed fixed aaaa".to_slice

    0.upto(7) do |compression_info|
      it_decodes_vector "DEFLATE-1950-2.2-cinfo", "accepts CINFO #{compression_info} (a #{256 << compression_info}-byte window)", :zlib,
        zlib_of(text_stream, compression_info: compression_info), TEXT
    end

    8.upto(15) do |compression_info|
      it_rejects_vector "DEFLATE-1950-2.2-cinfo", "rejects CINFO #{compression_info}", :zlib,
        zlib_of(text_stream, compression_info: compression_info), :malformed
    end

    wide = DeflateConformance.deflate do |deflate|
      deflate.stored(DeflateConformance.sample_bytes(32_768))
      deflate.fixed(final: true, &.match(258, 32_768).match(3, 257).match(4, 300))
    end
    it_decodes_vector "DEFLATE-1950-2.2-cinfo", "accepts distances up to 32,768 in a stream that declares a 256-byte window", :zlib,
      zlib_of(wide, compression_info: 0), wide.expected

    16.times do |method|
      next if method == 8
      it_rejects_vector "DEFLATE-1950-2.2-cm", "rejects compression method #{method}", :zlib,
        zlib_of(text_stream, method: method), :malformed
    end

    1.upto(30) do |adjustment|
      it_rejects_vector "DEFLATE-1950-2.2-fcheck", "rejects FCHECK off by #{adjustment}", :zlib,
        zlib_of(text_stream, check_adjustment: adjustment), :malformed
    end

    0.upto(3) do |level|
      it_decodes_vector "DEFLATE-1950-2.2-flevel", "decodes the same data whatever FLEVEL #{level} says", :zlib,
        zlib_of(text_stream, level: level), TEXT
    end

    it_rejects_vector "DEFLATE-1950-2.2-fcheck", "rejects a gzip header given as a zlib stream", :zlib,
      DeflateConformance.gzip_member(text_stream.to_slice, TEXT), :malformed
  end

  describe "preset dictionaries (RFC 1950 2.2)" do
    dictionary = "the quick brown fox jumps over the lazy dog".to_slice
    with_dictionary = DeflateConformance.deflate(dictionary) do |deflate|
      # "fox", "the quick" (the first dictionary byte) and "dog" (the last).
      deflate.fixed(final: true, &.match(3, 27).literal(' '.ord).match(9, 47).literal(' '.ord).match(3, 17).match(258, 1))
    end

    it_decodes_vector({"DEFLATE-1950-2.2-fdict", "DEFLATE-1950-2.2-dictionary-history"}, "copies from a preset dictionary, back to its first byte", :zlib,
      zlib_of(with_dictionary, dictionary: dictionary), with_dictionary.expected, dictionary)

    it_rejects_vector "DEFLATE-1950-2.2-fdict", "rejects a stream that needs a dictionary when none is given", :zlib,
      zlib_of(with_dictionary, dictionary: dictionary), :malformed

    it_rejects_vector "DEFLATE-1950-2.2-fdict", "rejects a dictionary whose Adler-32 is not the stream's DICTID", :zlib,
      zlib_of(with_dictionary, dictionary: dictionary), :checksum, "the quick brown fox jumps over the lazy cat".to_slice

    it_rejects_vector "DEFLATE-1950-2.2-fdict", "rejects an empty dictionary for a stream with another DICTID", :zlib,
      zlib_of(with_dictionary, dictionary: dictionary), :checksum, Bytes.empty

    it_decodes_vector "DEFLATE-1950-2.2-fdict", "reads DICTID most significant byte first", :zlib,
      DeflateConformance.join(Bytes[0x78, 0xbb, 0x61, 0x3c, 0x0f, 0xfa], with_dictionary.to_slice,
        Bytes.new(4) { |index| (DeflateConformance.reference_adler32(with_dictionary.expected) >> (24 - 8 * index)).to_u8! }),
      with_dictionary.expected, dictionary

    it_decodes_vector "DEFLATE-1950-2.2-dictionary-history", "decodes data that never refers to its dictionary", :zlib,
      zlib_of(text_stream, dictionary: dictionary), TEXT, dictionary

    it_rejects_vector "DEFLATE-1950-2.2-dictionary-history", "rejects a reference one byte before the dictionary", :zlib,
      zlib_of(DeflateConformance.deflate(dictionary, &.fixed(final: true, &.literal('a'.ord).length(257).distance(10, 12))), dictionary: dictionary), :malformed, dictionary

    large = DeflateConformance.sample_bytes(32_768, 11_u32)
    reaching = DeflateConformance.deflate(large, &.fixed(final: true, &.match(258, 32_768).match(258, 32_768).match(3, 1)))
    it_decodes_vector "DEFLATE-1950-2.2-dictionary-history", "reaches 32,768 bytes back into a 32,768-byte dictionary", :zlib,
      zlib_of(reaching, dictionary: large), reaching.expected, large

    # Only the last 32,768 bytes of a longer dictionary are history.
    longer = DeflateConformance.sample_bytes(40_000, 13_u32)
    tail = DeflateConformance.deflate(longer[40_000 - 32_768, 32_768], &.fixed(final: true, &.match(100, 32_768).match(100, 1_000)))
    it_decodes_vector "DEFLATE-1950-2.2-dictionary-history", "uses the last 32,768 bytes of a longer dictionary", :zlib,
      DeflateConformance.zlib_stream(tail.to_slice, tail.expected, dictionary: longer), tail.expected, longer

    it_rejects_vector "DEFLATE-1950-2.2-dictionary-history", "rejects a reference past the history a short dictionary and the output give", :zlib,
      zlib_of(DeflateConformance.deflate(dictionary, &.fixed(final: true, &.literals("abc").length(257).distance(10, 15))), dictionary: dictionary), :malformed, dictionary

    crossing = DeflateConformance.deflate(dictionary) do |deflate|
      deflate.stored("stored ".to_slice)
      deflate.fixed(final: true, &.match(20, 15).match(43, 70))
    end
    it_decodes_vector "DEFLATE-1950-2.2-dictionary-history", "copies a match that starts in the dictionary and ends in the output", :zlib,
      zlib_of(crossing, dictionary: dictionary), crossing.expected, dictionary
  end

  describe "the Adler-32 trailer (RFC 1950 2.2)" do
    it_decodes_vector "DEFLATE-1950-2.2-adler32", "accepts the Adler-32 of 65,535 bytes of 0xff, most significant byte first", :zlib,
      zlib_of(DeflateConformance.deflate(&.stored(Bytes.new(65_535, 0xff_u8), final: true))), Bytes.new(65_535, 0xff_u8)

    4.times do |index|
      it_rejects_vector "DEFLATE-1950-2.2-adler32", "reports a wrong Adler-32 byte #{index} as a checksum error", :zlib,
        zlib_of(text_stream, adler: DeflateConformance.reference_adler32(TEXT) ^ (1_u32 << (8 * index + 3))), :checksum
    end

    it_rejects_vector "DEFLATE-1950-2.2-adler32", "reports an Adler-32 stored least significant byte first as a checksum error", :zlib,
      zlib_of(text_stream, adler: DeflateConformance.reference_adler32(TEXT).byte_swap), :checksum

    it_rejects_vector "DEFLATE-1950-2.2-adler32", "reports the CRC-32 in the place of the Adler-32 as a checksum error", :zlib,
      zlib_of(text_stream, adler: DeflateConformance.reference_crc32(TEXT)), :checksum

    it_rejects_vector "DEFLATE-1950-2.2-adler32", "reports an Adler-32 of 1 for data that is not empty as a checksum error", :zlib,
      zlib_of(text_stream, adler: 1_u32), :checksum

    preset = "preset".to_slice
    it_decodes_vector "DEFLATE-1950-2.2-adler32", "leaves the dictionary out of the Adler-32", :zlib,
      zlib_of(DeflateConformance.deflate(preset, &.fixed(final: true, &.match(6, 6).literals("!"))), dictionary: preset), "preset!".to_slice, preset
  end

  describe "the end of the stream" do
    valid = zlib_of(text_stream)
    it_rejects_vector "DEFLATE-API-trailing-data", "rejects a byte after the Adler-32", :zlib, DeflateConformance.join(valid, Bytes[0]), :malformed
    it_rejects_vector "DEFLATE-API-trailing-data", "rejects a second zlib stream after the first", :zlib, DeflateConformance.join(valid, valid), :malformed

    it_rejects_vector "DEFLATE-API-truncation", "reports empty input as truncated", :zlib, Bytes.empty, :truncated
    {1 => "after CMF", 2 => "after FLG", 10 => "inside the DEFLATE data", valid.size - 4 => "before the Adler-32", valid.size - 3 => "after one Adler-32 byte", valid.size - 1 => "one byte before the end"}.each do |size, place|
      it_rejects_vector "DEFLATE-API-truncation", "reports a stream cut #{place} as truncated", :zlib, valid[0, size], :truncated
    end

    dictionary = "dictionary".to_slice
    with_dictionary = zlib_of(DeflateConformance.deflate(dictionary, &.fixed(final: true, &.match(10, 10))), dictionary: dictionary)
    {3 => "inside DICTID", 6 => "after DICTID"}.each do |size, place|
      it_rejects_vector "DEFLATE-API-truncation", "reports a stream cut #{place} as truncated", :zlib, with_dictionary[0, size], :truncated, dictionary
    end

    it_satisfies "DEFLATE-API-truncation", "reports every proper prefix of a stream as truncated" do
      DeflateConformance.check_every_prefix_is_truncated(:zlib, valid)
      DeflateConformance.check_every_prefix_is_truncated(:zlib, with_dictionary, dictionary)
    end

    it_satisfies "DEFLATE-API-errors", "raises ChecksumError, a MalformedStreamError, for a wrong Adler-32" do
      input = zlib_of(text_stream, adler: 0_u32)
      error = expect_raises(Mica::Deflate::ChecksumError) do
        Mica::Zlib.decode(input, limits: DeflateConformance::LIMITS, timeout: nil)
      end
      error.should be_a(Mica::Deflate::MalformedStreamError)
      error.should be_a(Mica::ParseError)
      (input.size - 4..input.size).should contain(error.byte_offset)
    end
  end
end
