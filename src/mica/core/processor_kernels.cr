module Mica::Core
  # Tells which instructions the processor running this program has, so
  # that each hot kernel (CRC-32, Adler-32) can choose, once at startup,
  # between a body written for those instructions and its generic body.
  # Every variant gives the same result as the generic body, bit for bit;
  # only the speed differs.
  #
  # - Apple silicon: every such processor has the ARMv8 CRC-32
  #   instructions and Advanced SIMD (NEON), so the answer is known when the
  #   program is compiled.
  # - Linux on AArch64: the kernel lists the CRC-32 instructions in the
  #   auxiliary vector (`AT_HWCAP`), read once when the program starts.
  #   Advanced SIMD is part of the architecture.
  # - x86-64: CPUID lists `pclmulqdq`, SSE4.1, AVX2 and BMI2, and XCR0 says
  #   whether the operating system saves the 256-bit registers, read once
  #   when the program starts.
  # - Anywhere else: none.
  #
  # A program compiled with `-Dmica_generic_kernels` runs the generic body
  # of every kernel, so a benchmark can compare both on one machine and the
  # test suite can run the generic bodies on a machine that has the
  # instructions.
  #
  # ```
  # Mica::Core::ProcessorKernels.chosen_variants # => {"crc32" => "armv8-crc", "adler32" => "armv8-neon"}
  # ```
  module ProcessorKernels
    {% if flag?(:aarch64) && flag?(:linux) %}
      lib LibAuxiliaryVector
        fun getauxval(type : LibC::ULong) : LibC::ULong
      end

      # `AT_HWCAP` and its `HWCAP_CRC32` bit (Linux
      # `arch/arm64/include/uapi/asm/hwcap.h`).
      private HARDWARE_CAPABILITIES_ENTRY = 16
      private CRC32_CAPABILITY            = 1_u64 << 7

      private def self.has_capability?(capability : UInt64) : Bool
        LibAuxiliaryVector.getauxval(HARDWARE_CAPABILITIES_ENTRY).to_u64 & capability != 0
      end
    {% elsif flag?(:x86_64) %}
      # Returns the EAX, EBX, ECX and EDX registers that CPUID gives for
      # *leaf* and *subleaf*.
      private def self.processor_identification(leaf : UInt32, subleaf : UInt32) : {UInt32, UInt32, UInt32, UInt32}
        eax = 0_u32
        ebx = 0_u32
        ecx = 0_u32
        edx = 0_u32
        asm("cpuid" : "={eax}"(eax), "={ebx}"(ebx), "={ecx}"(ecx), "={edx}"(edx) : "{eax}"(leaf), "{ecx}"(subleaf))
        {eax, ebx, ecx, edx}
      end

      # Bit *bit* of ECX in leaf 1: `pclmulqdq` is bit 1, SSSE3 bit 9,
      # SSE4.1 bit 19, SSE4.2 bit 20, POPCNT bit 23, OSXSAVE bit 27 and AVX
      # bit 28.
      private def self.has_leaf1_bit?(bit : Int32) : Bool
        processor_identification(1_u32, 0_u32)[2].bit(bit) == 1
      end

      # Bit *bit* of EBX in leaf 7, subleaf 0 (AVX2 is bit 5, BMI2 bit 8),
      # or false where the processor has no leaf 7.
      private def self.has_leaf7_bit?(bit : Int32) : Bool
        highest_leaf = processor_identification(0_u32, 0_u32)[0]
        return false if highest_leaf < 7

        processor_identification(7_u32, 0_u32)[1].bit(bit) == 1
      end

      # Whether the operating system saves the 256-bit YMM registers (XCR0
      # bits 1 and 2), which AVX2 needs. `xgetbv` is only allowed once
      # OSXSAVE says so.
      private def self.saves_256_bit_registers? : Bool
        return false unless has_leaf1_bit?(27) && has_leaf1_bit?(28)

        low = 0_u32
        high = 0_u32
        asm("xgetbv" : "={eax}"(low), "={edx}"(high) : "{ecx}"(0_u32))
        low & 0b110 == 0b110
      end
    {% end %}

    # What the processor has, whatever this program was compiled to use:
    # the ARMv8 CRC-32 instructions (`crc32x` folds eight bytes into a CRC-32
    # in one instruction); the x86-64 carry-less multiply (`pclmulqdq`)
    # together with SSE4.1 (`pextrd`), which the folding CRC-32 uses; and
    # AVX2 on registers the operating system saves.
    {% if flag?(:aarch64) && flag?(:darwin) %}
      private CRC32_INSTRUCTIONS_FOUND = true
    {% elsif flag?(:aarch64) && flag?(:linux) %}
      private CRC32_INSTRUCTIONS_FOUND = has_capability?(CRC32_CAPABILITY)
    {% else %}
      private CRC32_INSTRUCTIONS_FOUND = false
    {% end %}
    {% if flag?(:x86_64) %}
      private CARRYLESS_MULTIPLY_FOUND = has_leaf1_bit?(1) && has_leaf1_bit?(19)
      private AVX2_FOUND               = saves_256_bit_registers? && has_leaf7_bit?(5)
    {% else %}
      private CARRYLESS_MULTIPLY_FOUND = false
      private AVX2_FOUND               = false
    {% end %}

    # What the kernels use: what the processor has, or nothing under
    # `-Dmica_generic_kernels`.
    {% if flag?(:mica_generic_kernels) %}
      HAS_CRC32_INSTRUCTIONS = false
      HAS_CARRYLESS_MULTIPLY = false
      HAS_AVX2               = false
    {% else %}
      HAS_CRC32_INSTRUCTIONS = CRC32_INSTRUCTIONS_FOUND
      HAS_CARRYLESS_MULTIPLY = CARRYLESS_MULTIPLY_FOUND
      HAS_AVX2               = AVX2_FOUND
    {% end %}

    # The variant each kernel runs on this processor, by kernel name, as
    # the benchmark harness records it.
    def self.chosen_variants : Hash(String, String)
      {
        "crc32"   => crc32_variant,
        "adler32" => adler32_variant,
      }
    end

    # The features found on this processor that some kernel can use, in
    # lowercase (`crc`, `pclmulqdq`, `sse4.1`, `avx2`, `neon`), also under
    # `-Dmica_generic_kernels`.
    def self.detected_features : Array(String)
      features = [] of String
      {% if flag?(:aarch64) %}
        features << "neon"
        features << "crc" if CRC32_INSTRUCTIONS_FOUND
      {% elsif flag?(:x86_64) %}
        features << "pclmulqdq" << "sse4.1" if CARRYLESS_MULTIPLY_FOUND
        features << "avx2" if AVX2_FOUND
      {% end %}
      features
    end

    private def self.crc32_variant : String
      if HAS_CRC32_INSTRUCTIONS
        "armv8-crc"
      elsif HAS_CARRYLESS_MULTIPLY
        "pclmul"
      else
        "generic"
      end
    end

    private def self.adler32_variant : String
      HAS_AVX2 ? "x86-64-v3" : "generic"
    end
  end
end
