module Mica::Deflate
  {% if flag?(:aarch64) && flag?(:darwin) %}
    # LLVM intrinsics for the ARMv8 CRC32 instructions (compiled inline;
    # nothing is linked).
    #
    # :nodoc:
    lib LibCRC32Instructions
      fun crc32x = "llvm.aarch64.crc32x"(crc : UInt32, data : UInt64) : UInt32
      fun crc32b = "llvm.aarch64.crc32b"(crc : UInt32, data : UInt32) : UInt32
    end
  {% end %}

  # CRC-32 as gzip uses it (ISO 3309, reflected polynomial 0xEDB88320),
  # computed eight bytes at a time with slicing-by-8 tables.
  #
  # ```
  # Mica::Deflate::CRC32.update(0_u32, "123456789".to_slice) # => 0xCBF43926
  # ```
  module CRC32
    # Eight 256-entry tables: table k maps a byte to its CRC contribution
    # k bytes ahead.
    TABLES = begin
      tables = StaticArray(UInt32, 2048).new(0_u32)
      256.times do |index|
        crc = index.to_u32
        8.times { crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB88320_u32 : crc >> 1 }
        tables[index] = crc
      end
      256.times do |index|
        crc = tables[index]
        (1...8).each do |slice|
          crc = tables[crc & 0xFF] ^ (crc >> 8)
          tables[slice * 256 + index] = crc
        end
      end
      tables
    end

    # Returns the CRC-32 of *bytes* continuing from *crc* (0 for a new
    # checksum).
    def self.update(crc : UInt32, bytes : Bytes) : UInt32
      update(crc, bytes.to_unsafe, bytes.size)
    end

    # :nodoc:
    def self.update(crc : UInt32, pointer : UInt8*, count : Int32) : UInt32
      {% if flag?(:aarch64) && flag?(:darwin) %}
        update_with_instructions(crc, pointer, count)
      {% else %}
        update_with_tables(crc, pointer, count)
      {% end %}
    end

    {% if flag?(:aarch64) && flag?(:darwin) %}
      # Every Apple silicon CPU has the ARMv8 CRC32 instructions (CRC32X
      # folds eight bytes into the CRC-32 in one instruction); LLVM emits
      # them for these intrinsics, so no library is involved.
      private def self.update_with_instructions(crc : UInt32, pointer : UInt8*, count : Int32) : UInt32
        crc = ~crc
        index = 0
        while index + 32 <= count
          words = uninitialized StaticArray(UInt64, 4)
          words.to_unsafe.as(UInt8*).copy_from(pointer + index, 32)
          crc = LibCRC32Instructions.crc32x(crc, words[0])
          crc = LibCRC32Instructions.crc32x(crc, words[1])
          crc = LibCRC32Instructions.crc32x(crc, words[2])
          crc = LibCRC32Instructions.crc32x(crc, words[3])
          index += 32
        end
        while index < count
          crc = LibCRC32Instructions.crc32b(crc, pointer[index].to_u32)
          index += 1
        end
        ~crc
      end
    {% end %}

    # :nodoc:
    def self.update_with_tables(crc : UInt32, pointer : UInt8*, count : Int32) : UInt32
      table = TABLES.to_unsafe
      crc = ~crc
      index = 0
      while index + 8 <= count
        word = uninitialized UInt64
        (pointerof(word).as(UInt8*)).copy_from(pointer + index, 8)
        {% if IO::ByteFormat::SystemEndian != IO::ByteFormat::LittleEndian %}
          word = word.byte_swap
        {% end %}
        low = word.to_u32! ^ crc
        high = (word >> 32).to_u32!
        crc = table[1792 + (low & 0xFF)] ^ table[1536 + ((low >> 8) & 0xFF)] ^
              table[1280 + ((low >> 16) & 0xFF)] ^ table[1024 + (low >> 24)] ^
              table[768 + (high & 0xFF)] ^ table[512 + ((high >> 8) & 0xFF)] ^
              table[256 + ((high >> 16) & 0xFF)] ^ table[high >> 24]
        index += 8
      end
      while index < count
        crc = table[(crc ^ pointer[index]) & 0xFF] ^ (crc >> 8)
        index += 1
      end
      ~crc
    end
  end

  # Adler-32 as zlib uses it (RFC 1950, section 8.2).
  #
  # ```
  # Mica::Deflate::Adler32.update(1_u32, "Wikipedia".to_slice) # => 0x11E60398
  # ```
  module Adler32
    # The largest prime below 65,536.
    MODULUS = 65_521_u32
    # The most bytes that can be summed before the 32-bit sums must be
    # reduced (zlib's NMAX).
    BLOCK = 5_552

    # Returns the Adler-32 of *bytes* continuing from *adler* (1 for a new
    # checksum).
    def self.update(adler : UInt32, bytes : Bytes) : UInt32
      update(adler, bytes.to_unsafe, bytes.size)
    end

    # :nodoc:
    def self.update(adler : UInt32, pointer : UInt8*, count : Int32) : UInt32
      low = (adler & 0xFFFF).to_u64
      high = (adler >> 16).to_u64
      index = 0
      while index < count
        size = Math.min(BLOCK, count - index)
        # Over a block of n bytes, low gains the byte sum and high gains
        # n times the old low plus the sum of each byte weighted by its
        # distance from the block's end: two independent reductions that
        # LLVM vectorizes. Within a block of at most 5,552 bytes both fit in
        # 32 bits (the weighted sum is at most 255 * 5,552 * 5,553 / 2).
        sum = 0_u32
        weighted = 0_u32
        block = pointer + index
        weight = size.to_u32
        offset = 0
        while offset < size
          byte = block[offset].to_u32
          sum &+= byte
          weighted &+= byte &* weight
          weight &-= 1
          offset &+= 1
        end
        high = (high &+ low &* size.to_u64 &+ weighted.to_u64) % MODULUS
        low = (low &+ sum.to_u64) % MODULUS
        index += size
      end
      ((high << 16) | low).to_u32
    end
  end
end
