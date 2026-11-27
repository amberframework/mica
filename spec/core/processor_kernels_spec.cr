require "../spec_helper"

# Every kernel variant this processor supports gives the generic body's
# result, bit for bit: randomized inputs from fixed seeds at every length
# from 0 to 1,100, lengths around each vector width and fold size, every
# start alignment from 0 to 15, running values carried in, and the edge
# cases (all zero bytes, all 0xFF bytes, the largest Adler-32 sums).
# Variants the processor lacks are listed as pending.

private alias Kernel = Proc(UInt32, UInt8*, Int32, UInt32)

private def kernel_lengths : Array(Int32)
  lengths = (0..1_100).to_a
  [2_048, 4_096, 5_552, 11_104, 12_288, 13_056, 24_576, 36_864, 65_536].each do |edge|
    (edge - 70..edge + 70).each { |length| lengths << length }
  end
  lengths << 200_003
  lengths
end

private def kernel_inputs(seed : UInt32) : Array(Bytes)
  random = Random.new(seed)
  longest = kernel_lengths.max + 16
  [
    Bytes.new(longest) { random.rand(256).to_u8 },
    Bytes.new(longest, 0_u8),
    Bytes.new(longest, 0xFF_u8),
    Bytes.new(longest) { |index| (index % 3 == 0 ? 0xFF : random.rand(4)).to_u8 },
  ]
end

private def compare_with_generic(generic : Kernel, variant : Kernel, starting_values : Array(UInt32)) : Int32
  compared = 0
  kernel_inputs(20261126_u32).each_with_index do |input, input_index|
    kernel_lengths.each_with_index do |length, length_index|
      alignment = (length_index &+ input_index) % 16
      starting_value = starting_values[length_index % starting_values.size]
      pointer = input.to_unsafe + alignment
      expected = generic.call(starting_value, pointer, length)
      actual = variant.call(starting_value, pointer, length)
      unless actual == expected
        fail "length #{length}, alignment #{alignment}, input #{input_index}, start #{starting_value.to_s(16)}: " \
             "#{actual.to_s(16)} instead of #{expected.to_s(16)}"
      end
      compared &+= 1
    end
  end
  compared
end

private CRC32_STARTS   = [0_u32, 0xFFFF_FFFF_u32, 0x1234_5678_u32, 0xCBF4_3926_u32]
private ADLER32_STARTS = [1_u32, 0xFFF0_FFF0_u32, 0x0001_FFF0_u32, 0x1234_5678_u32 % 65_521_u32]

describe Mica::Core::ProcessorKernels do
  it "names a variant for every kernel and lists the features it found" do
    variants = Mica::Core::ProcessorKernels.chosen_variants
    variants.keys.should eq(["crc32", "adler32"])
    features = Mica::Core::ProcessorKernels.detected_features
    {% if flag?(:mica_generic_kernels) %}
      variants.values.uniq.should eq(["generic"])
    {% end %}
    STDOUT.puts "\nchosen variants: #{variants}, features found: #{features}"
  end

  describe "CRC-32" do
    generic = Kernel.new { |crc, pointer, count| Mica::Deflate::CRC32.update_with_tables(crc, pointer, count) }

    {% if flag?(:aarch64) %}
      if Mica::Core::ProcessorKernels::HAS_CRC32_INSTRUCTIONS
        it "armv8-crc matches the generic body" do
          variant = Kernel.new { |crc, pointer, count| Mica::Deflate::CRC32.update_with_instructions(crc, pointer, count) }
          compare_with_generic(generic, variant, CRC32_STARTS).should eq(4 * kernel_lengths.size)
        end
      else
        pending "armv8-crc (no CRC-32 instructions on this processor or build)"
      end
    {% else %}
      pending "armv8-crc (not an AArch64 build)"
    {% end %}

    {% if flag?(:x86_64) %}
      if Mica::Core::ProcessorKernels::HAS_CARRYLESS_MULTIPLY
        it "pclmul matches the generic body" do
          variant = Kernel.new { |crc, pointer, count| Mica::Deflate::CRC32.update_with_carryless_multiply(crc, pointer, count) }
          compare_with_generic(generic, variant, CRC32_STARTS).should eq(4 * kernel_lengths.size)
        end
      else
        pending "pclmul (no pclmulqdq and SSE4.1 on this processor or build)"
      end
    {% else %}
      pending "pclmul (not an x86-64 build)"
    {% end %}

    it "dispatches to a variant that matches the generic body" do
      chosen = Kernel.new { |crc, pointer, count| Mica::Deflate::CRC32.update(crc, pointer, count) }
      compare_with_generic(generic, chosen, CRC32_STARTS).should eq(4 * kernel_lengths.size)
    end
  end

  describe "Adler-32" do
    generic = Kernel.new { |adler, pointer, count| Mica::Deflate::Adler32.update_generic(adler, pointer, count) }

    {% if flag?(:x86_64) %}
      if Mica::Core::ProcessorKernels::HAS_AVX2
        it "x86-64-v3 (AVX2) matches the generic body" do
          variant = Kernel.new { |adler, pointer, count| Mica::Deflate::Adler32.update_with_avx2(adler, pointer, count) }
          compare_with_generic(generic, variant, ADLER32_STARTS).should eq(4 * kernel_lengths.size)
        end
      else
        pending "x86-64-v3 (no AVX2 on this processor or build)"
      end
    {% else %}
      pending "x86-64-v3 (not an x86-64 build)"
    {% end %}

    it "dispatches to a variant that matches the generic body" do
      chosen = Kernel.new { |adler, pointer, count| Mica::Deflate::Adler32.update(adler, pointer, count) }
      compare_with_generic(generic, chosen, ADLER32_STARTS).should eq(4 * kernel_lengths.size)
    end
  end
end
