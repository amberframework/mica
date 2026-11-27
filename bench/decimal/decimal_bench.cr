# Times Mica::Decimal128 against the standard library's BigDecimal (GMP)
# and Float64 on money-shaped values: prices such as 1234.56 and 19.99,
# tax rates such as 0.07 and 0.0825, at 2 and 4 places.
#
# Usage: crystal-alpha build --release bench/decimal/decimal_bench.cr -o bin/decimal_bench
#        bin/decimal_bench [ROUNDS]     (default 9)
#
# Each operation runs over the same 1,024 operands, CALLS times per round;
# the reported figure is the median ns per operation over ROUNDS rounds.
# Every result feeds a checksum printed to stderr, so no call is skipped.
# Prints a TSV row per operation: operation, Decimal128, BigDecimal,
# Float64 (ns/op), then BigDecimal / Decimal128.
require "big"
require "../../src/mica/decimal"

module DecimalBench
  COUNT =     1_024
  CALLS = 2_000_000

  # Money-shaped texts: 2- and 4-place prices and rates.
  def self.texts : Array(String)
    random = Random::PCG32.new(20261127)
    Array.new(COUNT) do |index|
      case index % 4
      when 0 then "#{random.rand(1..9999)}.#{random.rand(100).to_s.rjust(2, '0')}"  # 1234.56
      when 1 then "#{random.rand(1..99)}.#{random.rand(100).to_s.rjust(2, '0')}"    # 19.99
      when 2 then "0.#{random.rand(1..20).to_s.rjust(2, '0')}"                      # 0.07
      else        "#{random.rand(0..999)}.#{random.rand(10000).to_s.rjust(4, '0')}" # 12.0825
      end
    end
  end

  def self.median_ns(rounds : Int32, & : Int32 -> Int64) : Float64
    sink = 0_i64
    times = Array(Float64).new(rounds) do
      started = Time.instant
      index = 0
      CALLS.times do
        sink &+= yield index
        index = (index &+ 1) & (COUNT - 1)
      end
      (Time.instant - started).total_nanoseconds / CALLS
    end
    STDERR.puts "checksum #{sink}"
    times.sort!
    times[rounds // 2]
  end

  def self.run(rounds : Int32) : Nil
    texts = self.texts
    decimals = texts.map { |text| Mica::Decimal128.parse(text) }
    bigs = texts.map { |text| BigDecimal.new(text) }
    floats = texts.map(&.to_f64)
    # The second operand of each binary operation: the next value.
    other = ->(index : Int32) { (index &+ 1) & (COUNT - 1) }

    rows = [] of {String, Float64, Float64, Float64}
    rows << {"parse",
             median_ns(rounds) { |i| Mica::Decimal128.parse(texts[i]).coefficient.to_i64! },
             median_ns(rounds) { |i| BigDecimal.new(texts[i]).scale.to_i64! },
             median_ns(rounds) { |i| texts[i].to_f64.to_i64! }}
    rows << {"to_s",
             median_ns(rounds) { |i| decimals[i].to_s.bytesize.to_i64 },
             median_ns(rounds) { |i| bigs[i].to_s.bytesize.to_i64 },
             median_ns(rounds) { |i| floats[i].to_s.bytesize.to_i64 }}
    rows << {"+",
             median_ns(rounds) { |i| (decimals[i] + decimals[other.call(i)]).coefficient.to_i64! },
             median_ns(rounds) { |i| (bigs[i] + bigs[other.call(i)]).scale.to_i64! },
             median_ns(rounds) { |i| (floats[i] + floats[other.call(i)]).to_i64! }}
    rows << {"*",
             median_ns(rounds) { |i| (decimals[i] * decimals[other.call(i)]).coefficient.to_i64! },
             median_ns(rounds) { |i| (bigs[i] * bigs[other.call(i)]).scale.to_i64! },
             median_ns(rounds) { |i| (floats[i] * floats[other.call(i)]).to_i64! }}
    products = decimals.map_with_index { |value, i| value * decimals[other.call(i)] }
    big_products = bigs.map_with_index { |value, i| value * bigs[other.call(i)] }
    float_products = floats.map_with_index { |value, i| value * floats[other.call(i)] }
    rows << {"round(2)",
             median_ns(rounds) { |i| products[i].round(2, :ties_even).coefficient.to_i64! },
             median_ns(rounds) { |i| big_products[i].round(2, mode: :ties_even).scale.to_i64! },
             median_ns(rounds) { |i| (float_products[i].round(2) * 100).to_i64! }}
    rows << {"compare",
             median_ns(rounds) { |i| (decimals[i] <=> decimals[other.call(i)]).to_i64 },
             median_ns(rounds) { |i| (bigs[i] <=> bigs[other.call(i)]).to_i64 },
             median_ns(rounds) { |i| (floats[i] <=> floats[other.call(i)] || 0).to_i64 }}

    puts "operation\tdecimal128_ns\tbigdecimal_ns\tfloat64_ns\tbigdecimal_over_decimal128"
    rows.each do |name, decimal, big, float|
      puts "#{name}\t#{decimal.round(2)}\t#{big.round(2)}\t#{float.round(2)}\t#{(big / decimal).round(2)}"
    end
  end
end

DecimalBench.run((ARGV[0]? || "9").to_i32)
