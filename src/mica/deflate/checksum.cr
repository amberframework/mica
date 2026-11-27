module Mica::Deflate
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
    #
    # Runs the variant `Core::ProcessorKernels` chose for this processor:
    # the ARMv8 CRC-32 instructions, the x86-64 carry-less multiply fold, or
    # the slicing-by-8 tables.
    def self.update(crc : UInt32, pointer : UInt8*, count : Int32) : UInt32
      {% if flag?(:aarch64) %}
        return update_with_instructions(crc, pointer, count) if Core::ProcessorKernels::HAS_CRC32_INSTRUCTIONS
      {% elsif flag?(:x86_64) %}
        return update_with_carryless_multiply(crc, pointer, count) if Core::ProcessorKernels::HAS_CARRYLESS_MULTIPLY
      {% end %}
      update_with_tables(crc, pointer, count)
    end

    {% if flag?(:aarch64) %}
      # Bytes per stream when three streams are folded side by side.
      LONG_STREAM  = 4_096
      SHORT_STREAM =   256

      # For a stream of *bytes* bytes: four 256-entry tables that move a
      # CRC register past that many bytes (multiply it by x^(8 * bytes)
      # modulo the polynomial), one table per byte of the register.
      private def self.shift_tables(bytes : Int32) : StaticArray(UInt32, 1024)
        tables = StaticArray(UInt32, 1024).new(0_u32)
        32.times do |bit|
          value = 1_u32 << bit
          (bytes // 8).times { value = crc32x(value, 0_u64) }
          base = (bit >> 3) * 256
          mask = 1 << (bit & 7)
          256.times { |index| tables[base + index] ^= value if index & mask != 0 }
        end
        tables
      end

      LONG_SHIFT        = shift_tables(LONG_STREAM)
      LONG_SHIFT_TWICE  = shift_tables(LONG_STREAM * 2)
      SHORT_SHIFT       = shift_tables(SHORT_STREAM)
      SHORT_SHIFT_TWICE = shift_tables(SHORT_STREAM * 2)

      # The ARMv8 CRC32X instruction: folds the eight bytes of *data* into
      # *crc*. It is written as inline assembly with `.arch_extension crc`
      # because the LLVM intrinsic only compiles when the target CPU is
      # declared to have the CRC extension, which a default build of Crystal
      # does not declare. Only called where `Core::ProcessorKernels` found
      # the extension (every Apple silicon CPU has it).
      @[AlwaysInline]
      private def self.crc32x(crc : UInt32, data : UInt64) : UInt32
        result = 0_u32
        asm(".arch_extension crc\n\tcrc32x ${0:w}, ${1:w}, $2" : "=r"(result) : "r"(crc), "r"(data))
        result
      end

      # The ARMv8 CRC32B instruction: folds the low byte of *data* into *crc*.
      @[AlwaysInline]
      private def self.crc32b(crc : UInt32, data : UInt32) : UInt32
        result = 0_u32
        asm(".arch_extension crc\n\tcrc32b ${0:w}, ${1:w}, ${2:w}" : "=r"(result) : "r"(crc), "r"(data))
        result
      end

      @[AlwaysInline]
      private def self.shifted(crc : UInt32, tables : UInt32*) : UInt32
        tables[crc & 0xFF] ^ tables[256_u32 &+ ((crc >> 8) & 0xFF)] ^ tables[512_u32 &+ ((crc >> 16) & 0xFF)] ^
          tables[768_u32 &+ (crc >> 24)]
      end

      @[AlwaysInline]
      private def self.word_at(pointer : UInt8*) : UInt64
        word = uninitialized UInt64
        pointerof(word).as(UInt8*).copy_from(pointer, 8)
        word
      end

      # Folds three streams of *stream* bytes each, starting at *pointer*,
      # into *crc*. The CRC32X instruction takes three cycles and a core
      # starts one per cycle, so three independent streams run at three
      # times the speed of one; the tables then move the first two
      # registers past the bytes that follow them.
      @[AlwaysInline]
      private def self.fold_three_streams(crc : UInt32, pointer : UInt8*, stream : Int32, shift_twice : UInt32*,
                                          shift_once : UInt32*) : UInt32
        first = crc
        second = 0_u32
        third = 0_u32
        second_pointer = pointer + stream
        third_pointer = second_pointer + stream
        offset = 0
        while offset < stream
          first = crc32x(first, word_at(pointer + offset))
          second = crc32x(second, word_at(second_pointer + offset))
          third = crc32x(third, word_at(third_pointer + offset))
          offset &+= 8
        end
        shifted(first, shift_twice) ^ shifted(second, shift_once) ^ third
      end

      # :nodoc:
      #
      # The CRC-32 on the ARMv8 CRC32 instructions (CRC32X folds eight
      # bytes into the CRC-32 in one instruction); the inline assembly above
      # emits them, so no library is involved. Only for a processor that has
      # them (`Core::ProcessorKernels::HAS_CRC32_INSTRUCTIONS`).
      def self.update_with_instructions(crc : UInt32, pointer : UInt8*, count : Int32) : UInt32
        crc = ~crc
        index = 0
        if count >= 3 * SHORT_STREAM
          long_twice = LONG_SHIFT_TWICE.to_unsafe
          long_once = LONG_SHIFT.to_unsafe
          while count &- index >= 3 * LONG_STREAM
            crc = fold_three_streams(crc, pointer + index, LONG_STREAM, long_twice, long_once)
            index &+= 3 * LONG_STREAM
          end
          short_twice = SHORT_SHIFT_TWICE.to_unsafe
          short_once = SHORT_SHIFT.to_unsafe
          while count &- index >= 3 * SHORT_STREAM
            crc = fold_three_streams(crc, pointer + index, SHORT_STREAM, short_twice, short_once)
            index &+= 3 * SHORT_STREAM
          end
        end
        while index &+ 8 <= count
          crc = crc32x(crc, word_at(pointer + index))
          index &+= 8
        end
        while index < count
          crc = crc32b(crc, pointer[index].to_u32)
          index &+= 1
        end
        ~crc
      end
    {% end %}

    {% if flag?(:x86_64) %}
      # The folding constants for the reflected polynomial 0xEDB88320, as
      # zlib's and Chromium's `crc32_simd.c` lay them out (Gopal et al.,
      # "Fast CRC Computation for Generic Polynomials Using PCLMULQDQ",
      # Intel, 2009): x^(4 * 128 + 32) and x^(4 * 128 - 32) modulo P to
      # fold four registers 64 bytes ahead; the same for one register 16
      # bytes ahead; x^64 modulo P; the Barrett constants (P and
      # floor(x^64 / P)); and the mask of each register's low 32-bit words.
      FOLD_CONSTANTS = StaticArray[
        0x0154442bd4_u64, 0x01c6e41596_u64,
        0x01751997d0_u64, 0x00ccaa009e_u64,
        0x0163cd6124_u64, 0x0000000000_u64,
        0x01db710641_u64, 0x01f7011641_u64,
        0x00ffffffff_u64, 0x00ffffffff_u64,
      ]

      # The fewest bytes the fold takes: four 16-byte registers.
      FOLD_MINIMUM = 64

      # :nodoc:
      #
      # The CRC-32 by carry-less multiplication: four 128-bit registers
      # fold 64 bytes per step, are folded into one, then reduced to 32 bits
      # with Barrett's method; the last bytes that do not fill a 16-byte
      # register go through the tables. Only for a processor that has
      # `pclmulqdq` and SSE4.1 (`Core::ProcessorKernels::HAS_CARRYLESS_MULTIPLY`).
      #
      # Registers: rsi input, rdx bytes left (a multiple of 16), rax
      # constants; xmm1 to xmm4 the four running registers, xmm0 the fold
      # constant.
      def self.update_with_carryless_multiply(crc : UInt32, pointer : UInt8*, count : Int32) : UInt32
        return update_with_tables(crc, pointer, count) if count < FOLD_MINIMUM

        folded = count & ~15
        state = ~crc
        result = 0_u32
        asm("
  mov $1, %rsi
  mov $2, %rdx
  mov $3, %rax
  movdqu (%rsi), %xmm1
  movdqu 16(%rsi), %xmm2
  movdqu 32(%rsi), %xmm3
  movdqu 48(%rsi), %xmm4
  movd $4, %xmm9
  pxor %xmm9, %xmm1
  movdqu (%rax), %xmm0
  add $$64, %rsi
  sub $$64, %rdx
  cmp $$64, %rdx
  jb 2f
1:
  movdqa %xmm1, %xmm5
  movdqa %xmm2, %xmm6
  movdqa %xmm3, %xmm7
  movdqa %xmm4, %xmm8
  pclmulqdq $$0x00, %xmm0, %xmm5
  pclmulqdq $$0x00, %xmm0, %xmm6
  pclmulqdq $$0x00, %xmm0, %xmm7
  pclmulqdq $$0x00, %xmm0, %xmm8
  pclmulqdq $$0x11, %xmm0, %xmm1
  pclmulqdq $$0x11, %xmm0, %xmm2
  pclmulqdq $$0x11, %xmm0, %xmm3
  pclmulqdq $$0x11, %xmm0, %xmm4
  movdqu (%rsi), %xmm9
  movdqu 16(%rsi), %xmm10
  movdqu 32(%rsi), %xmm11
  movdqu 48(%rsi), %xmm12
  pxor %xmm5, %xmm1
  pxor %xmm6, %xmm2
  pxor %xmm7, %xmm3
  pxor %xmm8, %xmm4
  pxor %xmm9, %xmm1
  pxor %xmm10, %xmm2
  pxor %xmm11, %xmm3
  pxor %xmm12, %xmm4
  add $$64, %rsi
  sub $$64, %rdx
  cmp $$64, %rdx
  jae 1b
2:
  movdqu 16(%rax), %xmm0
  movdqa %xmm1, %xmm5
  pclmulqdq $$0x00, %xmm0, %xmm5
  pclmulqdq $$0x11, %xmm0, %xmm1
  pxor %xmm2, %xmm1
  pxor %xmm5, %xmm1
  movdqa %xmm1, %xmm5
  pclmulqdq $$0x00, %xmm0, %xmm5
  pclmulqdq $$0x11, %xmm0, %xmm1
  pxor %xmm3, %xmm1
  pxor %xmm5, %xmm1
  movdqa %xmm1, %xmm5
  pclmulqdq $$0x00, %xmm0, %xmm5
  pclmulqdq $$0x11, %xmm0, %xmm1
  pxor %xmm4, %xmm1
  pxor %xmm5, %xmm1
  cmp $$16, %rdx
  jb 4f
3:
  movdqu (%rsi), %xmm2
  movdqa %xmm1, %xmm5
  pclmulqdq $$0x00, %xmm0, %xmm5
  pclmulqdq $$0x11, %xmm0, %xmm1
  pxor %xmm2, %xmm1
  pxor %xmm5, %xmm1
  add $$16, %rsi
  sub $$16, %rdx
  cmp $$16, %rdx
  jae 3b
4:
  movdqa %xmm1, %xmm2
  pclmulqdq $$0x10, %xmm0, %xmm2
  movdqu 64(%rax), %xmm3
  psrldq $$8, %xmm1
  pxor %xmm2, %xmm1
  movdqu 32(%rax), %xmm0
  movdqa %xmm1, %xmm2
  psrldq $$4, %xmm2
  pand %xmm3, %xmm1
  pclmulqdq $$0x00, %xmm0, %xmm1
  pxor %xmm2, %xmm1
  movdqu 48(%rax), %xmm0
  movdqa %xmm1, %xmm2
  pand %xmm3, %xmm2
  pclmulqdq $$0x10, %xmm0, %xmm2
  pand %xmm3, %xmm2
  pclmulqdq $$0x00, %xmm0, %xmm2
  pxor %xmm2, %xmm1
  pextrd $$1, %xmm1, $0
" : "=r"(result) : "r"(pointer), "r"(folded.to_i64), "r"(FOLD_CONSTANTS.to_unsafe), "r"(state)
  : "rax", "rdx", "rsi", "xmm0", "xmm1", "xmm2", "xmm3", "xmm4", "xmm5", "xmm6", "xmm7", "xmm8", "xmm9",
    "xmm10", "xmm11", "xmm12", "memory", "flags")
        update_with_tables(~result, pointer + folded, count - folded)
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
    #
    # Runs the variant `Core::ProcessorKernels` chose for this processor:
    # the AVX2 body on x86-64 processors that have it, otherwise the
    # generic body (which LLVM vectorizes for the baseline SSE2 or Advanced
    # SIMD registers).
    def self.update(adler : UInt32, pointer : UInt8*, count : Int32) : UInt32
      {% if flag?(:x86_64) %}
        return update_with_avx2(adler, pointer, count) if Core::ProcessorKernels::HAS_AVX2
      {% end %}
      update_generic(adler, pointer, count)
    end

    # The block sums of every body, written once.
    private macro sum_blocks
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

    # :nodoc:
    #
    # The generic body, the reference every variant matches.
    def self.update_generic(adler : UInt32, pointer : UInt8*, count : Int32) : UInt32
      sum_blocks
    end

    {% if flag?(:x86_64) %}
      # :nodoc:
      #
      # The same loop compiled for AVX2, whose 256-bit registers sum twice
      # the bytes per instruction. Only for a processor that has AVX2
      # (`Core::ProcessorKernels::HAS_AVX2`).
      @[TargetFeature("+avx2")]
      def self.update_with_avx2(adler : UInt32, pointer : UInt8*, count : Int32) : UInt32
        sum_blocks
      end
    {% end %}
  end
end
