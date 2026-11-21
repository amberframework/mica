require "./support/bit_writer"

# Conformance specs for gzip streams (RFC 1952) in Mica::Gzip: the member
# header and its optional fields in every flag combination, the header
# CRC, the CRC-32 and ISIZE trailer, and multi-member streams, around
# hand-built DEFLATE data.

private EXTRA_FIELD = Bytes[0x41, 0x70, 0x03, 0x00, 0x1f, 0x8b, 0x00]
private FILE_NAME   = "café.txt".encode("ISO-8859-1")
private COMMENT     = "a comment".to_slice

# A fixed-block DEFLATE stream of *text*.
private def fixed_stream(text : String) : Bytes
  DeflateConformance.deflate(&.fixed(final: true, &.literals(text))).to_slice
end

# One member holding *content*.
private def member(content : String, **options) : Bytes
  DeflateConformance.gzip_member(fixed_stream(content), content.to_slice, **options)
end

# The member whose optional fields are the ones the five low bits of
# *flags* select.
private def member_with_flags(flags : Int32, text : String) : Bytes
  member(text,
    text: flags & 0x01 != 0,
    header_crc: flags & 0x02 != 0,
    extra: flags & 0x04 != 0 ? EXTRA_FIELD : nil,
    file_name: flags & 0x08 != 0 ? FILE_NAME : nil,
    comment: flags & 0x10 != 0 ? COMMENT : nil,
    modification_time: 0x5f00_0000_u32 + flags.to_u32,
    extra_flags: flags.odd? ? 2_u8 : 4_u8,
    operating_system: flags.to_u8)
end

private def flag_names(flags : Int32) : String
  list_of_names = [] of String
  {"FTEXT", "FHCRC", "FEXTRA", "FNAME", "FCOMMENT"}.each_with_index do |name, bit|
    list_of_names << name if flags.bit(bit) == 1
  end
  list_of_names.empty? ? "no flags" : list_of_names.join(" + ")
end

# Decodes *input* through the Reader and returns the headers it reports.
private def headers_of(input : Bytes) : Array(Mica::Gzip::Header)
  reader = Mica::Gzip::Reader.new(IO::Memory.new(input), limits: DeflateConformance::LIMITS, timeout: nil)
  IO.copy(reader, IO::Memory.new)
  reader.list_of_headers
end

private def header_of(input : Bytes) : Mica::Gzip::Header
  list_of_headers = headers_of(input)
  list_of_headers.size.should eq(1)
  list_of_headers[0]
end

describe Mica::Gzip do
  describe "the member header (RFC 1952 2.3)" do
    it_decodes_vector({"DEFLATE-1952-2.3-magic", "DEFLATE-1952-2.3-cm", "DEFLATE-API-one-shot"}, "decodes a member with no optional fields", :gzip,
      member("plain member"), "plain member".to_slice)

    it_decodes_vector "DEFLATE-API-one-shot", "decodes a member of no data", :gzip, member(""), Bytes.empty

    32.times do |flags|
      it_decodes_vector "DEFLATE-1952-2.3-field-order", "decodes a member with #{flag_names(flags)}", :gzip,
        member_with_flags(flags, "member #{flags};"), "member #{flags};".to_slice
    end

    it_satisfies({"DEFLATE-1952-2.3-field-order", "DEFLATE-API-gzip-headers"}, "reports the fields of every flag combination") do
      32.times do |flags|
        header = header_of(member_with_flags(flags, "member #{flags};"))
        header.is_text.should eq(flags & 0x01 != 0)
        header.extra_field.should eq(flags & 0x04 != 0 ? EXTRA_FIELD : nil)
        header.file_name.should eq(flags & 0x08 != 0 ? FILE_NAME : nil)
        header.comment.should eq(flags & 0x10 != 0 ? COMMENT : nil)
        header.modification_time.should eq(0x5f00_0000_u32 + flags)
        header.extra_flags.should eq(flags.odd? ? 2 : 4)
        header.operating_system.should eq(flags)
      end
    end

    {0x20 => "bit 5", 0x40 => "bit 6", 0x80 => "bit 7", 0xe0 => "bits 5, 6 and 7", 0xff => "every bit"}.each do |flags, which|
      it_rejects_vector "DEFLATE-1952-2.3-reserved-flags", "rejects a member with reserved FLG #{which} set", :gzip,
        member("reserved", flags: flags.to_u8), :malformed
    end

    it_rejects_vector "DEFLATE-1952-2.3-reserved-flags", "rejects reserved FLG bit 5 beside valid optional fields", :gzip,
      member("reserved", file_name: FILE_NAME, header_crc: true, reserved_flags: 0x20), :malformed

    it_rejects_vector "DEFLATE-1952-2.3-reserved-flags", "rejects reserved FLG bits in a later member", :gzip,
      DeflateConformance.join(member("first"), member("second", flags: 0x40_u8)), :malformed

    it_rejects_vector "DEFLATE-1952-2.3-magic", "rejects a wrong ID1", :gzip, member("magic", first_magic: 0x1e_u8), :malformed
    it_rejects_vector "DEFLATE-1952-2.3-magic", "rejects a wrong ID2", :gzip, member("magic", second_magic: 0x8c_u8), :malformed
    it_rejects_vector "DEFLATE-1952-2.3-magic", "rejects ID1 and ID2 swapped", :gzip, member("magic", first_magic: 0x8b_u8, second_magic: 0x1f_u8), :malformed
    it_rejects_vector "DEFLATE-1952-2.3-magic", "rejects the old compress magic 1f 9d", :gzip, member("magic", second_magic: 0x9d_u8), :malformed
    it_rejects_vector "DEFLATE-1952-2.3-magic", "rejects a zlib stream", :gzip,
      DeflateConformance.zlib_stream(fixed_stream("zlib"), "zlib".to_slice), :malformed
    it_rejects_vector "DEFLATE-1952-2.3-magic", "rejects a raw DEFLATE stream", :gzip, fixed_stream("raw"), :malformed

    {0, 7, 9, 0x88, 0xff}.each do |method|
      it_rejects_vector "DEFLATE-1952-2.3-cm", "rejects compression method #{method}", :gzip, member("method", method: method.to_u8), :malformed
    end

    it_decodes_vector "DEFLATE-1952-2.3-ftext", "decodes binary data unchanged in a member marked FTEXT", :gzip,
      DeflateConformance.gzip_member(DeflateConformance.deflate(&.stored(Bytes[0, 13, 10, 255, 13, 10], final: true)).to_slice, Bytes[0, 13, 10, 255, 13, 10], text: true),
      Bytes[0, 13, 10, 255, 13, 10]

    it_satisfies "DEFLATE-1952-2.3-ftext", "reports FTEXT" do
      header_of(member("text", text: true)).is_text.should be_true
      header_of(member("text")).is_text.should be_false
    end

    {0_u32, 1_u32, 0x1234_5678_u32, 0x8000_0000_u32, 0xffff_ffff_u32}.each do |modification_time|
      it_decodes_vector "DEFLATE-1952-2.3-mtime-xfl-os", "accepts MTIME 0x#{modification_time.to_s(16)}", :gzip,
        member("mtime", modification_time: modification_time), "mtime".to_slice
    end

    {0, 1, 2, 4, 0xff}.each do |extra_flags|
      it_decodes_vector "DEFLATE-1952-2.3-mtime-xfl-os", "accepts XFL #{extra_flags}", :gzip,
        member("xfl", extra_flags: extra_flags.to_u8), "xfl".to_slice
    end

    {0, 3, 7, 13, 14, 200, 255}.each do |operating_system|
      it_decodes_vector "DEFLATE-1952-2.3-mtime-xfl-os", "accepts OS #{operating_system}", :gzip,
        member("os", operating_system: operating_system.to_u8), "os".to_slice
    end

    it_satisfies({"DEFLATE-1952-2.3-mtime-xfl-os", "DEFLATE-API-gzip-headers"}, "reports MTIME least significant byte first, XFL and OS") do
      input = member("fields", modification_time: 0x1234_5678_u32, extra_flags: 2_u8, operating_system: 3_u8)
      input[4, 4].should eq(Bytes[0x78, 0x56, 0x34, 0x12])
      header = header_of(input)
      header.modification_time.should eq(0x1234_5678_u32)
      header.extra_flags.should eq(2)
      header.operating_system.should eq(3)
      header.extra_field.should be_nil
      header.file_name.should be_nil
      header.comment.should be_nil
    end

    it_decodes_vector "DEFLATE-1952-2.3-fextra", "accepts an extra field of length 0", :gzip, member("extra", extra: Bytes.empty), "extra".to_slice
    it_decodes_vector "DEFLATE-1952-2.3-fextra", "accepts an extra field of 300 bytes (XLEN 2c 01)", :gzip,
      member("extra", extra: DeflateConformance.sample_bytes(300)), "extra".to_slice
    it_decodes_vector "DEFLATE-1952-2.3-fextra", "accepts an extra field of 65,535 bytes, the most XLEN can declare", :gzip,
      member("extra", extra: DeflateConformance.sample_bytes(65_535)), "extra".to_slice
    it_decodes_vector "DEFLATE-1952-2.3-fextra", "accepts an extra field that is not made of subfields", :gzip,
      member("extra", extra: Bytes[0xff, 0xff, 0xff]), "extra".to_slice

    it_satisfies({"DEFLATE-1952-2.3-fextra", "DEFLATE-API-gzip-headers"}, "reports the extra field bytes after XLEN") do
      header_of(member("extra", extra: EXTRA_FIELD)).extra_field.should eq(EXTRA_FIELD)
      header_of(member("extra", extra: Bytes.empty)).extra_field.should eq(Bytes.empty)
      long = DeflateConformance.sample_bytes(300)
      header_of(member("extra", extra: long, file_name: FILE_NAME)).extra_field.should eq(long)
    end

    it_decodes_vector "DEFLATE-1952-2.3-fname", "accepts an empty file name", :gzip, member("name", file_name: Bytes.empty), "name".to_slice
    it_decodes_vector "DEFLATE-1952-2.3-fname", "accepts a file name of 1,000 bytes", :gzip,
      member("name", file_name: Bytes.new(1_000, 0x61_u8)), "name".to_slice
    it_decodes_vector "DEFLATE-1952-2.3-fname", "accepts a file name of bytes that are not UTF-8", :gzip,
      member("name", file_name: Bytes[0xff, 0xfe, 0x80, 0x1f, 0x8b]), "name".to_slice

    it_satisfies({"DEFLATE-1952-2.3-fname", "DEFLATE-API-gzip-headers"}, "reports the file name bytes up to the terminating zero") do
      header_of(member("name", file_name: FILE_NAME)).file_name.should eq(FILE_NAME)
      header_of(member("name", file_name: Bytes.empty)).file_name.should eq(Bytes.empty)
      header_of(member("name", file_name: FILE_NAME, comment: COMMENT)).file_name.should eq(FILE_NAME)
    end

    it_decodes_vector "DEFLATE-1952-2.3-fcomment", "accepts an empty comment", :gzip, member("comment", comment: Bytes.empty), "comment".to_slice
    it_decodes_vector "DEFLATE-1952-2.3-fcomment", "accepts a comment of 5,000 bytes with line feeds", :gzip,
      member("comment", comment: Bytes.new(5_000) { |index| index % 80 == 79 ? 10_u8 : 0x63_u8 }), "comment".to_slice

    it_satisfies({"DEFLATE-1952-2.3-fcomment", "DEFLATE-API-gzip-headers"}, "reports the comment bytes up to the terminating zero") do
      header_of(member("comment", comment: COMMENT)).comment.should eq(COMMENT)
      header_of(member("comment", comment: Bytes.empty)).comment.should eq(Bytes.empty)
      header = header_of(member("comment", file_name: Bytes.empty, comment: COMMENT))
      header.file_name.should eq(Bytes.empty)
      header.comment.should eq(COMMENT)
    end

    it_decodes_vector "DEFLATE-1952-2.3-fhcrc", "accepts a correct header CRC over the fixed header", :gzip,
      member("hcrc", header_crc: true), "hcrc".to_slice
    it_decodes_vector "DEFLATE-1952-2.3-fhcrc", "accepts a correct header CRC over every optional field", :gzip,
      member("hcrc", header_crc: true, text: true, extra: EXTRA_FIELD, file_name: FILE_NAME, comment: COMMENT, modification_time: 0x0102_0304_u32), "hcrc".to_slice

    correct = (DeflateConformance.reference_crc32(member("hcrc", header_crc: true, file_name: FILE_NAME)[0, 10 + FILE_NAME.size + 1]) & 0xffff).to_u16
    {correct ^ 0x0001 => "a wrong low byte", correct ^ 0x8000 => "a wrong high byte", correct.byte_swap => "its bytes swapped", ~correct => "every bit flipped"}.each do |value, what|
      it_rejects_vector "DEFLATE-1952-2.3-fhcrc", "reports a header CRC with #{what} as a checksum error", :gzip,
        member("hcrc", header_crc: true, file_name: FILE_NAME, header_crc_value: value), :checksum
    end

    it_rejects_vector "DEFLATE-1952-2.3-fhcrc", "reports the high 16 bits of the CRC-32 as a checksum error", :gzip,
      member("hcrc", header_crc: true, header_crc_value: (DeflateConformance.reference_crc32(member("hcrc", header_crc: true)[0, 10]) >> 16).to_u16), :checksum

    {4 => "MTIME", 8 => "XFL", 9 => "OS", 13 => "the extra field", 21 => "the file name", 30 => "the comment"}.each do |offset, field|
      corrupt = member("hcrc", header_crc: true, extra: EXTRA_FIELD, file_name: FILE_NAME, comment: COMMENT).dup
      corrupt[offset] ^= 0x01_u8
      it_rejects_vector "DEFLATE-1952-2.3-fhcrc", "reports a header CRC that does not cover a changed byte of #{field} as a checksum error", :gzip, corrupt, :checksum
    end
  end

  describe "the member trailer (RFC 1952 2.3)" do
    text = "trailer check"
    crc = DeflateConformance.reference_crc32(text.to_slice)

    it_decodes_vector({"DEFLATE-1952-2.3-crc32", "DEFLATE-1952-2.3-isize"}, "accepts the CRC-32 and size of 70,000 bytes, least significant byte first", :gzip,
      DeflateConformance.gzip_member(
        DeflateConformance.deflate { |deflate| deflate.stored(DeflateConformance.sample_bytes(65_535)).stored(DeflateConformance.sample_bytes(4_465, 2_u32), final: true) }.to_slice,
        DeflateConformance.join(DeflateConformance.sample_bytes(65_535), DeflateConformance.sample_bytes(4_465, 2_u32))),
      DeflateConformance.join(DeflateConformance.sample_bytes(65_535), DeflateConformance.sample_bytes(4_465, 2_u32)))

    4.times do |index|
      it_rejects_vector "DEFLATE-1952-2.3-crc32", "reports a wrong CRC32 byte #{index} as a checksum error", :gzip,
        member(text, crc: crc ^ (1_u32 << (8 * index + 5))), :checksum
      it_rejects_vector "DEFLATE-1952-2.3-isize", "reports a wrong ISIZE byte #{index} as a checksum error", :gzip,
        member(text, size: text.bytesize.to_u32 ^ (1_u32 << (8 * index + 5))), :checksum
    end

    it_rejects_vector "DEFLATE-1952-2.3-crc32", "reports a CRC32 stored most significant byte first as a checksum error", :gzip,
      member(text, crc: crc.byte_swap), :checksum
    it_rejects_vector "DEFLATE-1952-2.3-crc32", "reports the Adler-32 in the place of the CRC32 as a checksum error", :gzip,
      member(text, crc: DeflateConformance.reference_adler32(text.to_slice)), :checksum
    it_rejects_vector "DEFLATE-1952-2.3-crc32", "reports a CRC32 of zero for data that is not empty as a checksum error", :gzip,
      member(text, crc: 0_u32), :checksum
    it_rejects_vector "DEFLATE-1952-2.3-isize", "reports an ISIZE one too small as a checksum error", :gzip,
      member(text, size: text.bytesize.to_u32 - 1), :checksum
    it_rejects_vector "DEFLATE-1952-2.3-isize", "reports an ISIZE of zero for data that is not empty as a checksum error", :gzip,
      member(text, size: 0_u32), :checksum
    it_rejects_vector "DEFLATE-1952-2.3-isize", "reports CRC32 and ISIZE in each other's place as a checksum error", :gzip,
      member(text, crc: text.bytesize.to_u32, size: crc), :checksum
    it_rejects_vector "DEFLATE-1952-2.3-isize", "reports a nonzero ISIZE for an empty member as a checksum error", :gzip,
      member("", size: 1_u32), :checksum

    it_satisfies "DEFLATE-API-errors", "raises ChecksumError, a MalformedStreamError, in the trailer" do
      input = member(text, crc: 0_u32)
      error = expect_raises(Mica::Deflate::ChecksumError) do
        Mica::Gzip.decode(input, limits: DeflateConformance::LIMITS, timeout: nil)
      end
      error.should be_a(Mica::Deflate::MalformedStreamError)
      (input.size - 8..input.size).should contain(error.byte_offset)
    end
  end

  describe "members (RFC 1952 2.2)" do
    it_decodes_vector "DEFLATE-1952-2.2-members", "concatenates the output of two members", :gzip,
      DeflateConformance.join(member("first, "), member("second")), "first, second".to_slice

    every_combination = DeflateConformance.join(Array.new(32) { |flags| member_with_flags(flags, "member #{flags};") })
    it_decodes_vector({"DEFLATE-1952-2.2-members", "DEFLATE-1952-2.3-field-order"}, "decodes 32 members, one with each flag combination", :gzip,
      every_combination, (0...32).join { |flags| "member #{flags};" }.to_slice)

    it_satisfies({"DEFLATE-1952-2.2-members", "DEFLATE-API-gzip-headers"}, "reports one header per member, in order") do
      list_of_headers = headers_of(every_combination)
      list_of_headers.size.should eq(32)
      list_of_headers.each_with_index do |header, flags|
        header.operating_system.should eq(flags)
        header.is_text.should eq(flags.odd?)
        header.extra_field.should eq(flags & 0x04 != 0 ? EXTRA_FIELD : nil)
        header.file_name.should eq(flags & 0x08 != 0 ? FILE_NAME : nil)
        header.comment.should eq(flags & 0x10 != 0 ? COMMENT : nil)
      end
    end

    it_satisfies "DEFLATE-API-gzip-headers", "reports a member's header once the member is being read" do
      input = DeflateConformance.join(member("first", file_name: "one".to_slice), member("second", file_name: "two".to_slice))
      reader = Mica::Gzip::Reader.new(IO::Memory.new(input), limits: DeflateConformance::LIMITS, timeout: nil)
      buffer = Bytes.new(5)
      reader.read_fully(buffer)
      String.new(buffer).should eq("first")
      reader.list_of_headers.first.file_name.should eq("one".to_slice)
      String.new(reader.getb_to_end).should eq("second")
      reader.list_of_headers.map(&.file_name).should eq(["one".to_slice, "two".to_slice])
    end

    stored_data = DeflateConformance.sample_bytes(500)
    mixed = DeflateConformance.join(
      member(""),
      DeflateConformance.gzip_member(DeflateConformance.deflate(&.stored(stored_data, final: true)).to_slice, stored_data),
      member(""),
      member("fixed"),
      DeflateConformance.gzip_member(DeflateConformance.deflate(&.dynamic(Array.new(257) { |symbol| symbol == 122 || symbol == 256 ? 1 : 0 }, [0], final: true, &.literals("zzz"))).to_slice, "zzz".to_slice),
      member(""))
    it_decodes_vector "DEFLATE-1952-2.2-members", "decodes empty members and members of each block type", :gzip,
      mixed, DeflateConformance.join(stored_data, "fixedzzz".to_slice)

    it_rejects_vector "DEFLATE-1952-2.2-members", "starts each member with an empty history", :gzip,
      DeflateConformance.join(member("history"),
        DeflateConformance.gzip_member(DeflateConformance.deflate(&.fixed(final: true, &.length(257).distance(2))).to_slice, "tor".to_slice)), :malformed

    it_rejects_vector({"DEFLATE-1952-2.2-members", "DEFLATE-1952-2.3-crc32"}, "checks the CRC32 of the second member", :gzip,
      DeflateConformance.join(member("first"), member("second", crc: DeflateConformance.reference_crc32("first".to_slice))), :checksum)

    it_rejects_vector({"DEFLATE-1952-2.2-members", "DEFLATE-1952-2.3-crc32"}, "checks each CRC32 against its own member, not the whole output", :gzip,
      DeflateConformance.join(member("first"), member("second", crc: DeflateConformance.reference_crc32("firstsecond".to_slice))), :checksum)

    it_rejects_vector({"DEFLATE-1952-2.2-members", "DEFLATE-1952-2.3-isize"}, "checks each ISIZE against its own member, not the whole output", :gzip,
      DeflateConformance.join(member("first"), member("second", size: 11_u32)), :checksum)

    it_rejects_vector({"DEFLATE-1952-2.2-members", "DEFLATE-1952-2.3-crc32"}, "checks the CRC32 of the first member before the second", :gzip,
      DeflateConformance.join(member("first", crc: 0_u32), member("second")), :checksum)

    it_rejects_vector "DEFLATE-API-trailing-data", "rejects two zero bytes after a member", :gzip,
      DeflateConformance.join(member("data"), Bytes[0, 0]), :malformed
    it_rejects_vector "DEFLATE-API-trailing-data", "rejects zero padding after a member", :gzip,
      DeflateConformance.join(member("data"), Bytes.new(512)), :malformed
    it_rejects_vector "DEFLATE-API-trailing-data", "rejects text after a member", :gzip,
      DeflateConformance.join(member("data"), "trailing garbage".to_slice), :malformed
    it_rejects_vector "DEFLATE-API-trailing-data", "rejects ID1 followed by a wrong ID2 after a member", :gzip,
      DeflateConformance.join(member("data"), Bytes[0x1f, 0x00]), :malformed
    it_rejects_vector "DEFLATE-API-trailing-data", "rejects a raw DEFLATE stream after a member", :gzip,
      DeflateConformance.join(member("data"), fixed_stream("data")), :malformed
    it_rejects_vector "DEFLATE-API-trailing-data", "rejects garbage after the third member", :gzip,
      DeflateConformance.join(member("one"), member("two"), member("three"), Bytes[0xff, 0xff]), :malformed

    it_rejects_vector "DEFLATE-API-truncation", "reports a lone ID1 after a member as truncated", :gzip,
      DeflateConformance.join(member("data"), Bytes[0x1f]), :truncated
    it_rejects_vector "DEFLATE-API-truncation", "reports a lone magic number after a member as truncated", :gzip,
      DeflateConformance.join(member("data"), Bytes[0x1f, 0x8b]), :truncated
    it_rejects_vector "DEFLATE-API-truncation", "reports a second member cut inside its DEFLATE data as truncated", :gzip,
      DeflateConformance.join(member("data"), member("second member")[0, 16]), :truncated
  end

  describe "truncation" do
    it_rejects_vector "DEFLATE-API-truncation", "reports empty input as truncated", :gzip, Bytes.empty, :truncated

    # 10 fixed bytes, XLEN and 7 extra bytes (to 19), 9 name bytes (to 28),
    # 10 comment bytes (to 38), CRC16 (to 40), then data and trailer.
    full = member("truncate me", text: true, header_crc: true, extra: EXTRA_FIELD, file_name: FILE_NAME, comment: COMMENT)
    {
      1 => "after ID1", 2 => "after the magic number", 3 => "after CM", 4 => "after FLG", 6 => "inside MTIME", 8 => "after MTIME", 9 => "after XFL",
      10 => "after OS", 11 => "inside XLEN", 12 => "after XLEN", 15 => "inside the extra field", 19 => "after the extra field",
      22 => "inside the file name", 27 => "before the file name's terminating zero", 28 => "after the file name",
      33 => "inside the comment", 37 => "before the comment's terminating zero", 38 => "after the comment",
      39 => "inside CRC16", 40 => "after CRC16", 45 => "inside the DEFLATE data", full.size - 8 => "before CRC32",
      full.size - 6 => "inside CRC32", full.size - 4 => "before ISIZE", full.size - 1 => "one byte before the end",
    }.each do |size, place|
      it_rejects_vector "DEFLATE-API-truncation", "reports a member cut #{place} as truncated", :gzip, full[0, size], :truncated
    end

    it_rejects_vector "DEFLATE-API-truncation", "reports an extra field shorter than its XLEN as truncated", :gzip,
      member("x", extra: EXTRA_FIELD, declared_extra_size: 65_535), :truncated

    it_satisfies "DEFLATE-API-truncation", "reports every proper prefix of a member as truncated" do
      DeflateConformance.check_every_prefix_is_truncated(:gzip, full)
      DeflateConformance.check_every_prefix_is_truncated(:gzip, member(""))
    end

    it_satisfies({"DEFLATE-API-truncation", "DEFLATE-1952-2.2-members"}, "reports every prefix of three members as truncated, except at the member ends") do
      first = member("one", file_name: FILE_NAME)
      second = member("", header_crc: true)
      third = member("three", comment: COMMENT)
      DeflateConformance.check_every_prefix_is_truncated(:gzip, DeflateConformance.join(first, second, third),
        list_of_complete_sizes: [first.size, first.size + second.size])
    end
  end
end
