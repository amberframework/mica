# Times each checksum kernel's variants against its generic body on this
# processor: median of ROUNDS rounds, each round enough calls to cover about
# 64 MiB of input per size. Each call continues from the previous result,
# so no call can be skipped or hoisted.
#
# Usage: crystal-alpha build --release bench/kernels/kernels_bench.cr -o bin/kernels_bench
#        bin/kernels_bench [ROUNDS]
#
# Prints one JSON object per line: the chosen variants and detected features
# first, then {"kernel", "variant", "size", "median_ns", "gb_per_s", "rounds"}
# for each kernel, variant and size.
require "json"
require "../../src/mica/deflate"

module KernelsBench
  SIZES           = [64, 1_024, 32_768, 1_048_576]
  BYTES_PER_ROUND = 64 * 1_048_576

  def self.median_ns(rounds : Int32, size : Int32, & : UInt32 -> UInt32) : Float64
    calls = Math.max(BYTES_PER_ROUND // size, 16)
    sink = 0_u32
    times = Array(Float64).new(rounds) do
      started = Time.instant
      calls.times { sink = yield sink }
      (Time.instant - started).total_nanoseconds / calls
    end
    STDERR.puts "checksum #{sink}"
    times.sort!
    (times[rounds // 2 - 1] + times[rounds // 2]) / 2
  end

  def self.report(kernel : String, variant : String, size : Int32, rounds : Int32, nanoseconds : Float64) : Nil
    puts({kernel: kernel, variant: variant, size: size, median_ns: nanoseconds.round(2),
          gb_per_s: (size / nanoseconds).round(3), rounds: rounds}.to_json)
  end

  def self.run(rounds : Int32) : Nil
    puts({chosen_variants:   Mica::Core::ProcessorKernels.chosen_variants,
          detected_features: Mica::Core::ProcessorKernels.detected_features}.to_json)
    random = Random.new(20261126)
    data = Bytes.new(SIZES.max + 64) { random.rand(256).to_u8 }
    pointer = data.to_unsafe + 3
    SIZES.each do |size|
      report("crc32", "generic", size, rounds, median_ns(rounds, size) { |seed| Mica::Deflate::CRC32.update_with_tables(seed, pointer, size) })
      {% if flag?(:aarch64) %}
        if Mica::Core::ProcessorKernels::HAS_CRC32_INSTRUCTIONS
          report("crc32", "armv8-crc", size, rounds, median_ns(rounds, size) { |seed| Mica::Deflate::CRC32.update_with_instructions(seed, pointer, size) })
        end
      {% elsif flag?(:x86_64) %}
        if Mica::Core::ProcessorKernels::HAS_CARRYLESS_MULTIPLY
          report("crc32", "pclmul", size, rounds, median_ns(rounds, size) { |seed| Mica::Deflate::CRC32.update_with_carryless_multiply(seed, pointer, size) })
        end
      {% end %}
      report("adler32", "generic", size, rounds, median_ns(rounds, size) { |seed| Mica::Deflate::Adler32.update_generic(seed, pointer, size) })
      {% if flag?(:aarch64) %}
        if Mica::Core::ProcessorKernels::HAS_ADVANCED_SIMD
          report("adler32", "armv8-neon", size, rounds, median_ns(rounds, size) { |seed| Mica::Deflate::Adler32.update_with_advanced_simd(seed, pointer, size) })
        end
      {% elsif flag?(:x86_64) %}
        if Mica::Core::ProcessorKernels::HAS_AVX2
          report("adler32", "x86-64-v3", size, rounds, median_ns(rounds, size) { |seed| Mica::Deflate::Adler32.update_with_avx2(seed, pointer, size) })
        end
      {% end %}
    end
  end
end

KernelsBench.run((ARGV[0]? || "6").to_i)
