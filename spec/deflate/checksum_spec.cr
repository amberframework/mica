require "./support/bit_writer"

# Specs for Mica::Deflate::CRC32 and Mica::Deflate::Adler32: the standard
# check values, and long and oddly sized inputs compared with references
# written straight from the RFC formulas (`reference_crc32` works bit by
# bit; `reference_adler32` reduces modulo 65521 at every byte).

private def crc32(text : String | Bytes) : UInt32
  Mica::Deflate::CRC32.update(0_u32, text.to_slice)
end

private def adler32(text : String | Bytes) : UInt32
  Mica::Deflate::Adler32.update(1_u32, text.to_slice)
end

describe Mica::Deflate::CRC32 do
  it_satisfies "DEFLATE-1952-8-crc32-algorithm", "gives the standard check value for \"123456789\"" do
    crc32("123456789").should eq(0xCBF43926_u32)
  end

  it_satisfies "DEFLATE-1952-8-crc32-algorithm", "gives the known CRC-32 of short strings" do
    crc32("").should eq(0_u32)
    crc32("a").should eq(0xE8B7BE43_u32)
    crc32("abc").should eq(0x352441C2_u32)
    crc32("message digest").should eq(0x20159D7F_u32)
    crc32("abcdefghijklmnopqrstuvwxyz").should eq(0x4C2750BD_u32)
    crc32("The quick brown fox jumps over the lazy dog").should eq(0x414FA339_u32)
    crc32(Bytes[0]).should eq(0xD202EF8D_u32)
    crc32(Bytes[0xff, 0xff, 0xff, 0xff]).should eq(0xFFFFFFFF_u32)
  end

  it_satisfies "DEFLATE-1952-8-crc32-algorithm", "matches the bit-by-bit formula for every length from 0 to 300 at every alignment" do
    data = DeflateConformance.sample_bytes(308)
    8.times do |offset|
      301.times do |size|
        piece = data[offset, size]
        crc32(piece).should eq(DeflateConformance.reference_crc32(piece))
      end
    end
  end

  it_satisfies "DEFLATE-1952-8-crc32-algorithm", "matches the bit-by-bit formula for long inputs" do
    random = DeflateConformance.sample_bytes(300_001, 42_u32)
    crc32(random).should eq(DeflateConformance.reference_crc32(random))
    zeros = Bytes.new(100_003)
    crc32(zeros).should eq(DeflateConformance.reference_crc32(zeros))
    ones = Bytes.new(100_003, 0xff_u8)
    crc32(ones).should eq(DeflateConformance.reference_crc32(ones))
  end

  it_satisfies "DEFLATE-1952-8-crc32-algorithm", "matches the table formula around every size where the folding changes" do
    # Three streams of 256 or 4,096 bytes are folded side by side where the
    # CPU has CRC-32 instructions: sizes around 768 and 12,288 bytes and
    # their multiples take every path through the fold and its tails.
    data = DeflateConformance.sample_bytes(40_000, 11_u32)
    sizes = [0, 1, 7, 8, 9, 31, 32, 33, 255, 256, 257]
    [768, 1_536, 2_304, 12_288, 13_056, 24_576, 36_864].each { |edge| (edge - 9..edge + 9).each { |size| sizes << size } }
    sizes << 40_000 - 3
    sizes.each do |size|
      3.times do |offset|
        piece = data[offset, size]
        Mica::Deflate::CRC32.update(0x1234_5678_u32, piece).should eq(
          Mica::Deflate::CRC32.update_with_tables(0x1234_5678_u32, piece.to_unsafe, piece.size))
      end
    end
  end

  it_satisfies "DEFLATE-API-checksums", "continues a running CRC-32 across every split of the input" do
    data = DeflateConformance.sample_bytes(200, 3_u32)
    whole = DeflateConformance.reference_crc32(data)
    201.times do |split|
      running = Mica::Deflate::CRC32.update(0_u32, data[0, split])
      Mica::Deflate::CRC32.update(running, data[split, data.size - split]).should eq(whole)
    end
  end

  it_satisfies "DEFLATE-API-checksums", "continues a running CRC-32 one byte at a time and over empty pieces" do
    data = DeflateConformance.sample_bytes(1_000, 5_u32)
    running = 0_u32
    data.size.times do |index|
      running = Mica::Deflate::CRC32.update(running, data[index, 1])
      running = Mica::Deflate::CRC32.update(running, Bytes.empty)
    end
    running.should eq(DeflateConformance.reference_crc32(data))
  end
end

describe Mica::Deflate::Adler32 do
  it_satisfies "DEFLATE-1950-8.2-adler32-algorithm", "gives the standard check value for \"Wikipedia\"" do
    adler32("Wikipedia").should eq(0x11E60398_u32)
  end

  it_satisfies "DEFLATE-1950-8.2-adler32-algorithm", "gives the known Adler-32 of short strings" do
    adler32("").should eq(1_u32)
    adler32("a").should eq(0x00620062_u32)
    adler32("abc").should eq(0x024D0127_u32)
    adler32("123456789").should eq(0x091E01DE_u32)
    adler32("message digest").should eq(0x29750586_u32)
    adler32("abcdefghijklmnopqrstuvwxyz").should eq(0x90860B20_u32)
    adler32(Bytes[0]).should eq(0x00010001_u32)
  end

  it_satisfies "DEFLATE-1950-8.2-adler32-algorithm", "matches the formula for every length from 0 to 300" do
    data = DeflateConformance.sample_bytes(300, 9_u32)
    301.times do |size|
      adler32(data[0, size]).should eq(DeflateConformance.reference_adler32(data[0, size]))
    end
  end

  it_satisfies "DEFLATE-1950-8.2-adler32-algorithm", "reduces modulo 65521 around the 5,552 bytes of 0xff that a 32-bit sum can hold" do
    {5_550, 5_551, 5_552, 5_553, 5_554, 11_104, 11_105, 65_520, 65_521, 65_522}.each do |size|
      data = Bytes.new(size, 0xff_u8)
      adler32(data).should eq(DeflateConformance.reference_adler32(data))
    end
  end

  it_satisfies "DEFLATE-1950-8.2-adler32-algorithm", "matches the formula for long inputs" do
    random = DeflateConformance.sample_bytes(1_000_003, 42_u32)
    adler32(random).should eq(DeflateConformance.reference_adler32(random))
    ones = Bytes.new(1_048_576, 0xff_u8)
    adler32(ones).should eq(DeflateConformance.reference_adler32(ones))
    zeros = Bytes.new(70_000)
    adler32(zeros).should eq(DeflateConformance.reference_adler32(zeros))
  end

  it_satisfies "DEFLATE-1950-8.2-adler32-algorithm", "wraps both sums when they pass 65521" do
    # s1 reaches 65520, then one more byte takes it to 0 modulo 65521.
    Mica::Deflate::Adler32.update(0xfff0_fff0_u32, Bytes[0x01]).should eq(0xfff0_0000_u32)
    Mica::Deflate::Adler32.update(0xfff0_fff0_u32, Bytes[0x02]).should eq(0x0000_0001_u32)
    Mica::Deflate::Adler32.update(0xfff0_fff0_u32, Bytes.new(6_000, 0xff_u8)).should eq(
      continue_reference(0xfff0_fff0_u32, Bytes.new(6_000, 0xff_u8)))
  end

  it_satisfies "DEFLATE-API-checksums", "continues a running Adler-32 across every split of the input" do
    data = DeflateConformance.sample_bytes(200, 3_u32)
    whole = DeflateConformance.reference_adler32(data)
    201.times do |split|
      running = Mica::Deflate::Adler32.update(1_u32, data[0, split])
      Mica::Deflate::Adler32.update(running, data[split, data.size - split]).should eq(whole)
    end
  end

  it_satisfies "DEFLATE-API-checksums", "continues a running Adler-32 across pieces longer than 5,552 bytes" do
    data = Bytes.new(40_000, 0xff_u8)
    running = 1_u32
    {1, 5_551, 5_553, 0, 11_111, 17_784}.reduce(0) do |offset, size|
      running = Mica::Deflate::Adler32.update(running, data[offset, size])
      offset + size
    end
    running.should eq(DeflateConformance.reference_adler32(data))
  end
end

# The RFC 1950 formula continued from the running value *adler*.
private def continue_reference(adler : UInt32, data : Bytes) : UInt32
  low = adler & 0xffff
  high = adler >> 16
  data.each do |byte|
    low = (low + byte) % 65_521_u32
    high = (high + low) % 65_521_u32
  end
  (high << 16) | low
end
