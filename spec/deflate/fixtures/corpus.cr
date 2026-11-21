# The attack and malformed corpora of spec/deflate/bomb_spec.cr: one recipe
# per case, written with the bit-level builders of fuzz/deflate_fuzz.cr.
#
# Small cases are files under spec/deflate/fixtures/attacks/ and
# spec/deflate/fixtures/malformed/ (written by generate_corpus.cr from the
# recipes here); cases that would be large files are built in the spec
# from the same recipes.
require "../../../fuzz/deflate_fuzz"

module DeflateCorpus
  alias Format = DeflateOracle::Format

  DIRECTORY = __DIR__

  # One malformed stream: its file under fixtures/malformed/, its
  # container, the error class Mica raises for it, the requirement it
  # covers, and (for the wrong-dictionary case) the file holding the
  # dictionary the caller supplies.
  record Malformed, file_name : String, format : Format, error_class_name : String, requirement_id : String,
    description : String, dictionary_file_name : String? = nil

  MALFORMED  = "Mica::Deflate::MalformedStreamError"
  TRUNCATED  = "Mica::Deflate::TruncatedStreamError"
  CHECKSUM   = "Mica::Deflate::ChecksumError"
  SAMPLE     = ("Mica inflates what zlib deflates. " * 6).to_slice
  DICTIONARY = "Mica inflates what zlib deflates, with a preset dictionary.".to_slice
  # A complete code-length code over all 19 symbols (13 codes of 4 bits, 6 of 5).
  EVERY_CODE_LENGTH_SYMBOL = Array.new(19) { |symbol| symbol < 13 ? 4 : 5 }

  LIST_OF_MALFORMED = [
    Malformed.new("raw-block-type-3.bin", Format::Raw, MALFORMED, "DEFLATE-1951-3.2.3-reserved-block-type", "block type 3"),
    Malformed.new("raw-stored-length-mismatch.bin", Format::Raw, MALFORMED, "DEFLATE-1951-3.2.4-stored-length", "stored block whose NLEN is not the complement of LEN"),
    Malformed.new("raw-distance-too-far.bin", Format::Raw, MALFORMED, "DEFLATE-1951-3.2.5-distance-too-far", "back reference before the first output byte"),
    Malformed.new("raw-literal-length-code-286.bin", Format::Raw, MALFORMED, "DEFLATE-1951-3.2.5-reserved-symbols", "literal/length symbol 286 in a fixed block"),
    Malformed.new("raw-distance-code-30.bin", Format::Raw, MALFORMED, "DEFLATE-1951-3.2.5-reserved-symbols", "distance symbol 30 in a fixed block"),
    Malformed.new("raw-oversubscribed-code.bin", Format::Raw, MALFORMED, "DEFLATE-1951-3.2.2-oversubscribed", "three literal/length codes of one bit"),
    Malformed.new("raw-incomplete-code.bin", Format::Raw, MALFORMED, "DEFLATE-1951-3.2.2-incomplete", "three literal/length codes of two bits"),
    Malformed.new("raw-no-end-of-block-code.bin", Format::Raw, MALFORMED, "DEFLATE-1951-3.2.7-end-of-block-code", "literal/length code without symbol 256"),
    Malformed.new("raw-repeat-without-previous-length.bin", Format::Raw, MALFORMED, "DEFLATE-1951-3.2.7-repeat-16", "repeat code 16 as the first code length"),
    Malformed.new("raw-repeat-past-last-length.bin", Format::Raw, MALFORMED, "DEFLATE-1951-3.2.7-repeat-overrun", "repeat code 18 running past HLIT + HDIST lengths"),
    Malformed.new("raw-hlit-287.bin", Format::Raw, MALFORMED, "DEFLATE-1951-3.2.7-hlit", "287 literal/length code lengths"),
    Malformed.new("raw-hdist-31.bin", Format::Raw, MALFORMED, "DEFLATE-1951-3.2.7-hdist", "31 distance code lengths"),
    Malformed.new("raw-incomplete-code-length-code.bin", Format::Raw, MALFORMED, "DEFLATE-1951-3.2.7-code-length-code", "incomplete code-length code"),
    Malformed.new("raw-unused-distance-code.bin", Format::Raw, MALFORMED, "DEFLATE-1951-3.2.2-unused-code", "the unused code of a single-code distance tree"),
    Malformed.new("raw-length-without-distance-codes.bin", Format::Raw, MALFORMED, "DEFLATE-1951-3.2.7-no-distance-codes", "length symbol in a block with no distance codes"),
    Malformed.new("raw-trailing-byte.bin", Format::Raw, MALFORMED, "DEFLATE-API-trailing-data", "one byte after the final block"),
    Malformed.new("raw-missing-final-block.bin", Format::Raw, TRUNCATED, "DEFLATE-1951-3.2.3-final-block", "no block sets BFINAL"),
    Malformed.new("raw-truncated-stored-data.bin", Format::Raw, TRUNCATED, "DEFLATE-API-truncation", "stored block cut inside its data"),
    Malformed.new("raw-truncated-dynamic-header.bin", Format::Raw, TRUNCATED, "DEFLATE-API-truncation", "dynamic block cut inside its code lengths"),
    Malformed.new("zlib-bad-header-check.bin", Format::Zlib, MALFORMED, "DEFLATE-1950-2.2-fcheck", "FCHECK off by one"),
    Malformed.new("zlib-bad-compression-method.bin", Format::Zlib, MALFORMED, "DEFLATE-1950-2.2-cm", "CM 7"),
    Malformed.new("zlib-cinfo-8.bin", Format::Zlib, MALFORMED, "DEFLATE-1950-2.2-cinfo", "CINFO 8 (a 64 KiB window)"),
    Malformed.new("zlib-fdict-without-dictionary.bin", Format::Zlib, MALFORMED, "DEFLATE-1950-2.2-fdict", "FDICT set, no dictionary supplied"),
    Malformed.new("zlib-wrong-dictionary.bin", Format::Zlib, CHECKSUM, "DEFLATE-1950-2.2-fdict", "FDICT set, another dictionary supplied", "zlib-wrong-dictionary.dictionary.bin"),
    Malformed.new("zlib-bad-adler32.bin", Format::Zlib, CHECKSUM, "DEFLATE-1950-2.2-adler32", "Adler-32 with one bit flipped"),
    Malformed.new("zlib-truncated-adler32.bin", Format::Zlib, TRUNCATED, "DEFLATE-API-truncation", "two of the four Adler-32 bytes"),
    Malformed.new("zlib-truncated-dictionary-id.bin", Format::Zlib, TRUNCATED, "DEFLATE-API-truncation", "FDICT set, DICTID cut short"),
    Malformed.new("zlib-trailing-garbage.bin", Format::Zlib, MALFORMED, "DEFLATE-API-trailing-data", "bytes after the Adler-32"),
    Malformed.new("gzip-bad-magic.bin", Format::Gzip, MALFORMED, "DEFLATE-1952-2.3-magic", "ID2 0x8c"),
    Malformed.new("gzip-bad-compression-method.bin", Format::Gzip, MALFORMED, "DEFLATE-1952-2.3-cm", "CM 7"),
    Malformed.new("gzip-reserved-flag-bit-5.bin", Format::Gzip, MALFORMED, "DEFLATE-1952-2.3-reserved-flags", "FLG bit 5 set"),
    Malformed.new("gzip-reserved-flag-bit-6.bin", Format::Gzip, MALFORMED, "DEFLATE-1952-2.3-reserved-flags", "FLG bit 6 set"),
    Malformed.new("gzip-reserved-flag-bit-7.bin", Format::Gzip, MALFORMED, "DEFLATE-1952-2.3-reserved-flags", "FLG bit 7 set"),
    Malformed.new("gzip-bad-header-crc.bin", Format::Gzip, CHECKSUM, "DEFLATE-1952-2.3-fhcrc", "FHCRC off by one"),
    Malformed.new("gzip-bad-crc32.bin", Format::Gzip, CHECKSUM, "DEFLATE-1952-2.3-crc32", "CRC32 with one bit flipped"),
    Malformed.new("gzip-bad-isize.bin", Format::Gzip, CHECKSUM, "DEFLATE-1952-2.3-isize", "ISIZE off by one"),
    Malformed.new("gzip-truncated-header.bin", Format::Gzip, TRUNCATED, "DEFLATE-API-truncation", "five of the ten fixed header bytes"),
    Malformed.new("gzip-truncated-file-name.bin", Format::Gzip, TRUNCATED, "DEFLATE-API-truncation", "FNAME with no terminating zero"),
    Malformed.new("gzip-truncated-trailer.bin", Format::Gzip, TRUNCATED, "DEFLATE-API-truncation", "five of the eight trailer bytes"),
    Malformed.new("gzip-trailing-garbage.bin", Format::Gzip, MALFORMED, "DEFLATE-API-trailing-data", "bytes after a member that do not start another member"),
    Malformed.new("gzip-bad-second-member.bin", Format::Gzip, CHECKSUM, "DEFLATE-1952-2.2-members", "a valid member followed by one with a wrong CRC32"),
  ]

  # Returns a raw DEFLATE stream written by the block.
  def self.raw(& : DeflateFuzz::BitWriter ->) : Bytes
    writer = DeflateFuzz::BitWriter.new
    yield writer
    writer.to_slice
  end

  FIXED_LITERAL  = DeflateFuzz::HuffmanCode.new(DeflateFuzz::FIXED_LITERAL_LENGTHS)
  FIXED_DISTANCE = DeflateFuzz::HuffmanCode.new(DeflateFuzz::FIXED_DISTANCE_LENGTHS)

  # Starts a block: BFINAL and BTYPE.
  def self.block(writer : DeflateFuzz::BitWriter, type : Int32, is_final : Bool = true) : Nil
    writer.bits(is_final ? 1 : 0, 1)
    writer.bits(type, 2)
  end

  # Returns *size* code lengths, zero except the symbols in *assigned*.
  def self.lengths(size : Int32, assigned : Hash(Int32, Int32)) : Array(Int32)
    list_of_lengths = Array.new(size, 0)
    assigned.each { |symbol, length| list_of_lengths[symbol] = length }
    list_of_lengths
  end

  # Writes a dynamic block header whose code-length code covers all 19 symbols.
  def self.code_tables(writer : DeflateFuzz::BitWriter, literal_count : Int32, distance_count : Int32,
                       list_of_symbols : Array(DeflateFuzz::LengthSymbol),
                       code_length_lengths : Array(Int32) = EVERY_CODE_LENGTH_SYMBOL) : Nil
    DeflateFuzz.write_code_tables(writer, literal_count, distance_count, code_length_lengths, 19, list_of_symbols)
  end

  # The raw DEFLATE of `SAMPLE`.
  def self.sample_raw : Bytes
    DeflateOracle.compress(SAMPLE, level: 9)
  end

  # Returns the bytes of the malformed case *file_name*.
  def self.malformed_bytes(file_name : String) : Bytes
    literal_a_and_end = lengths(258, {97 => 2, 256 => 2, 257 => 1})
    case file_name
    when "raw-block-type-3.bin"
      raw { |writer| block(writer, 3) }
    when "raw-stored-length-mismatch.bin"
      raw do |writer|
        block(writer, 0)
        writer.align
        writer.bits(5, 16)
        writer.bits(0xFFFB, 16)
        writer.bytes("hello".to_slice)
      end
    when "raw-distance-too-far.bin"
      raw do |writer|
        block(writer, 1)
        FIXED_LITERAL.write(writer, 97)
        FIXED_LITERAL.write(writer, 257)
        FIXED_DISTANCE.write(writer, 1)
        FIXED_LITERAL.write(writer, 256)
      end
    when "raw-literal-length-code-286.bin"
      raw do |writer|
        block(writer, 1)
        FIXED_LITERAL.write(writer, 97)
        FIXED_LITERAL.write(writer, 286)
        FIXED_LITERAL.write(writer, 256)
      end
    when "raw-distance-code-30.bin"
      raw do |writer|
        block(writer, 1)
        FIXED_LITERAL.write(writer, 97)
        FIXED_LITERAL.write(writer, 257)
        FIXED_DISTANCE.write(writer, 30)
        FIXED_LITERAL.write(writer, 256)
      end
    when "raw-oversubscribed-code.bin"
      dynamic_block(lengths(257, {0 => 1, 1 => 1, 256 => 1}), [1])
    when "raw-incomplete-code.bin"
      dynamic_block(lengths(257, {0 => 2, 1 => 2, 256 => 2}), [1])
    when "raw-no-end-of-block-code.bin"
      dynamic_block(lengths(257, {0 => 1, 1 => 1}), [1])
    when "raw-repeat-without-previous-length.bin"
      raw do |writer|
        block(writer, 2)
        list_of_symbols = DeflateFuzz.run_length_encode(lengths(257, {0 => 1, 256 => 1}) + [1])
        code_tables(writer, 257, 1, list_of_symbols.unshift(DeflateFuzz::LengthSymbol.new(16, 0)))
      end
    when "raw-repeat-past-last-length.bin"
      raw do |writer|
        block(writer, 2)
        # 138 + 112 zero lengths, then 138 more where only 8 remain.
        list_of_symbols = [DeflateFuzz::LengthSymbol.new(18, 127), DeflateFuzz::LengthSymbol.new(18, 101),
                           DeflateFuzz::LengthSymbol.new(18, 127)]
        code_tables(writer, 257, 1, list_of_symbols)
      end
    when "raw-hlit-287.bin"
      raw do |writer|
        block(writer, 2)
        code_tables(writer, 287, 1, DeflateFuzz.run_length_encode(lengths(287, {0 => 1, 256 => 1}) + [1]))
        writer.bits(1, 1)
      end
    when "raw-hdist-31.bin"
      raw do |writer|
        block(writer, 2)
        code_tables(writer, 257, 31, DeflateFuzz.run_length_encode(lengths(257, {0 => 1, 256 => 1}) + lengths(31, {0 => 1})))
        writer.bits(1, 1)
      end
    when "raw-incomplete-code-length-code.bin"
      raw do |writer|
        block(writer, 2)
        list_of_symbols = DeflateFuzz.run_length_encode(lengths(257, {0 => 1, 256 => 1}) + [1])
        code_tables(writer, 257, 1, list_of_symbols, lengths(19, {0 => 2, 1 => 2, 18 => 2}))
      end
    when "raw-unused-distance-code.bin"
      raw do |writer|
        block(writer, 2)
        literal, _ = DeflateFuzz.write_dynamic_header(writer, literal_a_and_end, [1])
        literal.write(writer, 97)
        literal.write(writer, 257)
        writer.bits(1, 1)
        literal.write(writer, 256)
      end
    when "raw-length-without-distance-codes.bin"
      raw do |writer|
        block(writer, 2)
        literal, _ = DeflateFuzz.write_dynamic_header(writer, literal_a_and_end, [0])
        literal.write(writer, 97)
        literal.write(writer, 257)
        writer.bits(0, 8)
        literal.write(writer, 256)
      end
    when "raw-trailing-byte.bin"
      DeflateFuzz.join(sample_raw, Bytes[0])
    when "raw-missing-final-block.bin"
      raw do |writer|
        block(writer, 1, is_final: false)
        FIXED_LITERAL.write(writer, 97)
        FIXED_LITERAL.write(writer, 256)
      end
    when "raw-truncated-stored-data.bin"
      raw do |writer|
        block(writer, 0)
        writer.align
        writer.bits(5, 16)
        writer.bits(0xFFFA, 16)
        writer.bytes("hel".to_slice)
      end
    when "raw-truncated-dynamic-header.bin"
      DeflateOracle.compress(Bytes.new(600) { |index| (index * 7 % 251).to_u8 }, level: 9)[0, 12]
    when "zlib-bad-header-check.bin"
      DeflateFuzz.zlib_stream(sample_raw, SAMPLE, check_delta: 1)
    when "zlib-bad-compression-method.bin"
      DeflateFuzz.zlib_stream(sample_raw, SAMPLE, method: 7)
    when "zlib-cinfo-8.bin"
      DeflateFuzz.zlib_stream(sample_raw, SAMPLE, window_code: 8)
    when "zlib-fdict-without-dictionary.bin"
      DeflateOracle.compress(SAMPLE, Format::Zlib, level: 9, dictionary: DICTIONARY)
    when "zlib-wrong-dictionary.bin"
      DeflateOracle.compress(SAMPLE, Format::Zlib, level: 9, dictionary: DICTIONARY)
    when "zlib-wrong-dictionary.dictionary.bin"
      "Another dictionary than the one the stream was written with.".to_slice
    when "zlib-bad-adler32.bin"
      DeflateFuzz.zlib_stream(sample_raw, SAMPLE, adler: DeflateOracle.adler32(SAMPLE) ^ 1)
    when "zlib-truncated-adler32.bin"
      DeflateFuzz.zlib_stream(sample_raw, SAMPLE, trailer_bytes: 2)
    when "zlib-truncated-dictionary-id.bin"
      DeflateOracle.compress(SAMPLE, Format::Zlib, level: 9, dictionary: DICTIONARY)[0, 4]
    when "zlib-trailing-garbage.bin"
      DeflateFuzz.join(DeflateFuzz.zlib_stream(sample_raw, SAMPLE), "junk".to_slice)
    when "gzip-bad-magic.bin"
      DeflateFuzz.gzip_member(sample_raw, SAMPLE, magic: Bytes[0x1F, 0x8C])
    when "gzip-bad-compression-method.bin"
      DeflateFuzz.gzip_member(sample_raw, SAMPLE, method: 7)
    when "gzip-reserved-flag-bit-5.bin"
      DeflateFuzz.gzip_member(sample_raw, SAMPLE, reserved_bits: 1)
    when "gzip-reserved-flag-bit-6.bin"
      DeflateFuzz.gzip_member(sample_raw, SAMPLE, reserved_bits: 2)
    when "gzip-reserved-flag-bit-7.bin"
      DeflateFuzz.gzip_member(sample_raw, SAMPLE, reserved_bits: 4)
    when "gzip-bad-header-crc.bin"
      DeflateFuzz.gzip_member(sample_raw, SAMPLE, file_name: "sample.txt".to_slice, has_header_crc: true, header_crc_delta: 1)
    when "gzip-bad-crc32.bin"
      DeflateFuzz.gzip_member(sample_raw, SAMPLE, crc: DeflateOracle.crc32(SAMPLE) ^ 1)
    when "gzip-bad-isize.bin"
      DeflateFuzz.gzip_member(sample_raw, SAMPLE, size: SAMPLE.size.to_u32 + 1)
    when "gzip-truncated-header.bin"
      DeflateFuzz.gzip_member(sample_raw, SAMPLE)[0, 5]
    when "gzip-truncated-file-name.bin"
      DeflateFuzz.gzip_member(Bytes.empty, Bytes.empty, file_name: "sample.txt".to_slice, is_terminated: false, trailer_bytes: 0)
    when "gzip-truncated-trailer.bin"
      DeflateFuzz.gzip_member(sample_raw, SAMPLE, trailer_bytes: 5)
    when "gzip-trailing-garbage.bin"
      DeflateFuzz.join(DeflateFuzz.gzip_member(sample_raw, SAMPLE), "junk".to_slice)
    when "gzip-bad-second-member.bin"
      DeflateFuzz.join(DeflateFuzz.gzip_member(sample_raw, SAMPLE),
        DeflateFuzz.gzip_member(sample_raw, SAMPLE, crc: DeflateOracle.crc32(SAMPLE) ^ 0x8000_0000_u32))
    else
      raise ArgumentError.new("No malformed recipe named #{file_name}")
    end
  end

  # A final dynamic block with the given codes and nothing but the
  # end-of-block code (written as one 1 bit, whatever the code is).
  private def self.dynamic_block(literal_lengths : Array(Int32), distance_lengths : Array(Int32)) : Bytes
    raw do |writer|
      block(writer, 2)
      code_tables(writer, literal_lengths.size, distance_lengths.size,
        DeflateFuzz.run_length_encode(literal_lengths + distance_lengths))
      writer.bits(1, 1)
    end
  end

  # ---- attacks ----

  # The files under fixtures/attacks/.
  LIST_OF_ATTACK_FILES = ["raw-1032-to-1-16mib.bin", "zlib-1032-to-1-16mib.bin", "gzip-1032-to-1-16mib.bin",
                          "zlib-zeros-8mib.bin", "gzip-text-4mib.bin", "zlib-declares-32k-window.bin"]

  SIXTEEN_MIB = 16 * 1024 * 1024

  # Raw DEFLATE that expands at DEFLATE's ceiling, 1,032:1: one dynamic
  # block whose length code 285 (258 bytes) and whose only distance code
  # take one bit each, so every two bits of input repeat 258 zero bytes.
  # Returns the stream; it decodes to *output_bytes* zero bytes (rounded
  # down to 1 + a multiple of 258).
  def self.densest_stream(output_bytes : Int32) : Bytes
    raw do |writer|
      block(writer, 2)
      literal, distance = DeflateFuzz.write_dynamic_header(writer, lengths(286, {0 => 2, 256 => 2, 285 => 1}), [1])
      literal.write(writer, 0)
      ((output_bytes - 1) // 258).times do
        literal.write(writer, 285)
        distance.write(writer, 0)
      end
      literal.write(writer, 256)
    end
  end

  # The size of what `densest_stream(output_bytes)` decodes to.
  def self.densest_output_size(output_bytes : Int32) : Int32
    1 + (output_bytes - 1) // 258 * 258
  end

  # 4 MiB of text with a 331-byte period: it compresses several hundred
  # to one, far past any lowered ratio and under DEFLATE's ceiling.
  def self.repetitive_text : Bytes
    line = "Mica::Gzip reads what gzip(1) writes; a ratio limit of 50:1 stops this body. "
    period = (line * 5).to_slice[0, 331]
    Bytes.new(4 * 1024 * 1024) { |index| period[index % period.size] }
  end

  # Returns the bytes of the attack file *file_name*.
  def self.attack_bytes(file_name : String) : Bytes
    zeros = Bytes.new(densest_output_size(SIXTEEN_MIB))
    case file_name
    when "raw-1032-to-1-16mib.bin"
      densest_stream(SIXTEEN_MIB)
    when "zlib-1032-to-1-16mib.bin"
      DeflateFuzz.zlib_stream(densest_stream(SIXTEEN_MIB), zeros)
    when "gzip-1032-to-1-16mib.bin"
      DeflateFuzz.gzip_member(densest_stream(SIXTEEN_MIB), zeros)
    when "zlib-zeros-8mib.bin"
      DeflateOracle.compress(Bytes.new(8 * 1024 * 1024), Format::Zlib, level: 9)
    when "gzip-text-4mib.bin"
      DeflateOracle.compress(repetitive_text, Format::Gzip, level: 9)
    when "zlib-declares-32k-window.bin"
      DeflateFuzz.zlib_stream(sample_raw, SAMPLE, window_code: 7)
    else
      raise ArgumentError.new("No attack recipe named #{file_name}")
    end
  end

  # *count* gzip members, each an empty stream (20 bytes).
  def self.empty_gzip_members(count : Int32) : Bytes
    member = DeflateFuzz.gzip_member(Bytes[0x03, 0x00], Bytes.empty)
    io = IO::Memory.new(member.size * count)
    count.times { io.write(member) }
    io.to_slice
  end

  # *count* empty stored blocks (5 bytes each), the last one final.
  def self.empty_stored_blocks(count : Int32) : Bytes
    io = IO::Memory.new(count * 5)
    count.times { |index| io.write(Bytes[index == count - 1 ? 1 : 0, 0x00, 0x00, 0xFF, 0xFF]) }
    io.to_slice
  end

  # *count* dynamic blocks that hold only their end-of-block code, the
  # last one final. Each block declares all 286 literal/length codes and
  # all 30 distance codes, so a decoder rebuilds its largest tables for
  # every 30 bytes of input.
  def self.empty_dynamic_blocks(count : Int32) : Bytes
    literal_lengths = Array.new(286) { |symbol| symbol < 226 ? 8 : 9 }
    distance_lengths = Array.new(30) { |symbol| symbol < 2 ? 4 : 5 }
    raw do |writer|
      count.times do |index|
        block(writer, 2, is_final: index == count - 1)
        literal, _ = DeflateFuzz.write_dynamic_header(writer, literal_lengths, distance_lengths)
        literal.write(writer, 256)
      end
    end
  end

  # A stored block of *distance* bytes, then a match that reaches back
  # exactly *distance* bytes (distance symbol 29 holds 24,577..32,768).
  def self.far_back_reference(distance : Int32) : Bytes
    raw do |writer|
      block(writer, 0, is_final: false)
      writer.align
      writer.bits(distance, 16)
      writer.bits(distance ^ 0xFFFF, 16)
      writer.bytes(Bytes.new(distance) { |index| (index % 251).to_u8 })
      block(writer, 1)
      FIXED_LITERAL.write(writer, 257)
      FIXED_DISTANCE.write(writer, 29)
      writer.bits(distance - 24_577, 13)
      FIXED_LITERAL.write(writer, 256)
    end
  end

  # Writes every file of both corpora under *directory*.
  def self.write_files(directory : String = DIRECTORY) : Array(String)
    list_of_paths = [] of String
    LIST_OF_MALFORMED.each do |entry|
      list_of_paths << write_file(File.join(directory, "malformed", entry.file_name), malformed_bytes(entry.file_name))
      if dictionary_file_name = entry.dictionary_file_name
        list_of_paths << write_file(File.join(directory, "malformed", dictionary_file_name), malformed_bytes(dictionary_file_name))
      end
    end
    LIST_OF_ATTACK_FILES.each do |file_name|
      list_of_paths << write_file(File.join(directory, "attacks", file_name), attack_bytes(file_name))
    end
    list_of_paths
  end

  private def self.write_file(path : String, bytes : Bytes) : String
    Dir.mkdir_p(File.dirname(path))
    File.write(path, bytes)
    path
  end

  # Reads a corpus file.
  def self.read(kind : String, file_name : String) : Bytes
    File.open(File.join(DIRECTORY, kind, file_name), &.getb_to_end)
  end
end
