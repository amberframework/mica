# Differential test of Mica::Decimal128 against the standard library's
# BigDecimal (GMP) as the oracle: seeded random operations on operands of
# up to 38 digits, each result compared digit for digit and scale for
# scale, and each overflow, inexact or division-by-zero outcome compared
# with the error the oracle's exact result calls for.
#
#   crystal-alpha build --release scripts/decimal_differential.cr -o bin/decimal_differential
#   bin/decimal_differential [SEED] [OPERATIONS]     (defaults 20261127 1000000)
#
# Exits 1 when any operation differs. The oracle computes every result in
# exact BigDecimal/BigInt arithmetic with its own rounding code; nothing in
# it calls Mica.
require "big"
require "../src/mica/decimal"

module DecimalDifferential
  alias Decimal = Mica::Decimal128
  alias Mode = Mica::Decimal128::RoundingMode

  MAX = BigInt.new(10) ** 38 - 1
  TEN = BigInt.new(10)

  # The outcome of one operation: plain text, or the name of an error.
  alias Outcome = String

  # Plain text of coefficient / 10**scale, written by the oracle.
  def self.plain(coefficient : BigInt, scale : Int32) : String
    digits = coefficient.abs.to_s
    text = if scale == 0
             digits
           elsif digits.size > scale
             "#{digits[0, digits.size - scale]}.#{digits[digits.size - scale, scale]}"
           else
             "0.#{"0" * (scale - digits.size)}#{digits}"
           end
    coefficient < 0 ? "-#{text}" : text
  end

  # The coefficient of *value* at *scale*, or nil when it is not an integer.
  def self.coefficient_at(value : BigDecimal, scale : Int32) : BigInt?
    numerator = value.value * TEN ** scale
    denominator = TEN ** value.scale
    return nil unless numerator % denominator == 0
    numerator.tdiv(denominator)
  end

  def self.fits(coefficient : BigInt, scale : Int32) : Outcome
    coefficient.abs > MAX || scale > 38 ? "OverflowError" : plain(coefficient, scale)
  end

  # The outcome for an exact result at *scale*.
  def self.exact(value : BigDecimal, scale : Int32) : Outcome
    fits(coefficient_at(value, scale) || raise("an exact result has more digits than its scale"), scale)
  end

  # Rounds numerator / denominator (denominator > 0) to an integer.
  def self.round_quotient(numerator : BigInt, denominator : BigInt, mode : Mode) : BigInt?
    floor = numerator // denominator
    rest = numerator - floor * denominator
    return floor if rest == 0
    case mode
    in .floor?     then floor
    in .ceiling?   then floor + 1
    in .truncate?  then numerator < 0 ? floor + 1 : floor
    in .ties_away? then numerator < 0 ? -((-numerator * 2 + denominator) // (denominator * 2)) : (numerator * 2 + denominator) // (denominator * 2)
    in .ties_even?
      twice = rest * 2
      if twice > denominator
        floor + 1
      elsif twice < denominator
        floor
      else
        floor.even? ? floor : floor + 1
      end
    in .unnecessary? then nil
    end
  end

  def self.oracle_divide(a : BigDecimal, b : BigDecimal, scale : Int32, mode : Mode) : Outcome
    return "DivisionByZeroError" if b.value == 0
    # a / b at scale: a.value * 10**(b.scale + scale) / (b.value * 10**a.scale).
    numerator = a.value * TEN ** (b.scale.to_i32 + scale)
    denominator = b.value * TEN ** a.scale.to_i32
    if denominator < 0
      numerator = -numerator
      denominator = -denominator
    end
    return "OverflowError" if numerator.abs.tdiv(denominator) > MAX
    rounded = round_quotient(numerator, denominator, mode)
    return "InexactError" if rounded.nil?
    fits(rounded, scale)
  end

  def self.oracle_round(a : BigDecimal, scale : Int32, mode : Mode) : Outcome
    return plain(a.value, a.scale.to_i32) if scale >= a.scale
    if mode.unnecessary?
      exact = coefficient_at(a, scale)
      return exact ? plain(exact, scale) : "InexactError"
    end
    stdlib_mode = case mode
                  when .ties_away? then Number::RoundingMode::TIES_AWAY
                  when .ties_even? then Number::RoundingMode::TIES_EVEN
                  when .floor?     then Number::RoundingMode::TO_NEGATIVE
                  when .ceiling?   then Number::RoundingMode::TO_POSITIVE
                  else                  Number::RoundingMode::TO_ZERO
                  end
    rounded = a.round(scale, mode: stdlib_mode)
    plain(coefficient_at(rounded, scale) || raise("oracle round left digits"), scale)
  end

  def self.oracle_rescale(a : BigDecimal, scale : Int32, mode : Mode) : Outcome
    return oracle_round(a, scale, mode) if scale < a.scale
    fits(coefficient_at(a, scale) || raise("unreachable"), scale)
  end

  # The value and scale `Decimal128.parse` must give for *text*: the written
  # scale clamped to 0..38, lowered while the coefficient has more than 38
  # digits, never below the scale the value needs.
  def self.oracle_parse(text : String, natural_scale : Int64) : Outcome
    value = BigDecimal.new(text)
    scale = natural_scale.clamp(0_i64, 38_i64).to_i32
    return plain(BigInt.new(0), scale) if value.value == 0
    while scale >= 0
      coefficient = coefficient_at(value, scale)
      return "OverflowError" if coefficient.nil?
      return plain(coefficient, scale) if coefficient.abs <= MAX
      scale -= 1
    end
    "OverflowError"
  end

  def self.outcome(&) : Outcome
    yield.to_s
  rescue error : Mica::Decimal128::Error
    error.class.name.split("::").last
  end

  # A random operand as {text, coefficient, scale}.
  def self.operand(random : Random) : String
    case random.rand(10)
    when 0..3 # money shapes: up to 9 digits, scale 0 to 4
      digits = random.rand(1..9)
      scale = random.rand(0..4)
    when 4..7
      digits = random.rand(1..38)
      scale = random.rand(0..38)
    when 8 # all nines, or 10**k
      digits = random.rand(1..38)
      scale = random.rand(0..38)
      coefficient = random.rand(2) == 0 ? TEN ** digits - 1 : TEN ** (digits - 1)
      coefficient = -coefficient if random.rand(2) == 0
      return plain(coefficient, scale)
    else # zero, or a single digit at an extreme scale
      scale = random.rand(0..38)
      return plain(BigInt.new(random.rand(10)) * (random.rand(2) == 0 ? 1 : -1), scale)
    end
    coefficient = BigInt.new(0)
    digits.times { coefficient = coefficient * 10 + random.rand(10) }
    coefficient = -coefficient if random.rand(2) == 0
    plain(coefficient, scale)
  end

  # A random operand that is a tie when rounded to the scale returned:
  # digits, then 5, then zeros.
  def self.tie_operand(random : Random) : {String, Int32}
    integer = random.rand(1..15)
    scale = random.rand(0..18)
    zeros = random.rand(0..3)
    digits = String.build { |io| (integer + scale).times { io << random.rand(10) } }
    sign = random.rand(2) == 0 ? "-" : ""
    {"#{sign}#{digits[0, integer]}.#{digits[integer, scale]}5#{"0" * zeros}", scale}
  end

  # A random text with an exponent, and the scale it asks for.
  def self.exponent_text(random : Random) : {String, Int64}
    integer = String.build { |io| random.rand(1..20).times { io << random.rand(10) } }
    fraction = random.rand(2) == 0 ? "" : String.build { |io| random.rand(1..25).times { io << random.rand(10) } }
    exponent = random.rand(-45..45)
    sign = random.rand(3) == 0 ? "-" : ""
    marker = random.rand(2) == 0 ? "e" : "E"
    exponent_sign = exponent < 0 ? "-" : (random.rand(2) == 0 ? "+" : "")
    text = "#{sign}#{integer}#{fraction.empty? ? "" : "."}#{fraction}#{marker}#{exponent_sign}#{exponent.abs}"
    {text, fraction.size.to_i64 - exponent}
  end

  def self.mode(random : Random) : Mode
    Mode.values[random.rand(Mode.values.size)]
  end

  def self.run(seed : UInt64, operations : Int32) : Int32
    random = Random::PCG32.new(seed)
    counts = Hash(String, Int32).new(0)
    errors = Hash(String, Int32).new(0)
    differences = 0
    operations.times do |index|
      text_a = operand(random)
      text_b = operand(random)
      a = Decimal.parse(text_a)
      b = Decimal.parse(text_b)
      big_a = BigDecimal.new(text_a)
      big_b = BigDecimal.new(text_b)
      kind = random.rand(9)
      name, ours, expected = case kind
                             when 0
                               {"+", outcome { a + b }, exact(big_a + big_b, Math.max(a.scale, b.scale))}
                             when 1
                               {"-", outcome { a - b }, exact(big_a - big_b, Math.max(a.scale, b.scale))}
                             when 2
                               product = big_a * big_b
                               scale = a.scale + b.scale
                               {"*", outcome { a * b }, scale > 38 ? "OverflowError" : exact(product, scale)}
                             when 3, 4
                               scale = random.rand(0..38)
                               mode = mode(random)
                               # Divisors of a few digits keep many quotients in range.
                               if random.rand(2) == 0
                                 text_b = plain(BigInt.new(random.rand(0..999)) * (random.rand(2) == 0 ? 1 : -1), random.rand(0..4))
                                 b = Decimal.parse(text_b)
                                 big_b = BigDecimal.new(text_b)
                               end
                               {"divide #{mode}", outcome { a.divide(b, scale, mode) }, oracle_divide(big_a, big_b, scale, mode)}
                             when 5
                               scale = random.rand(0..38)
                               mode = mode(random)
                               # Half the time, an exact tie at the rounding position.
                               if random.rand(2) == 0
                                 text_a, scale = tie_operand(random)
                                 a = Decimal.parse(text_a)
                                 big_a = BigDecimal.new(text_a)
                               end
                               {"round #{mode}", outcome { a.round(scale, mode) }, oracle_round(big_a, scale, mode)}
                             when 6
                               scale = random.rand(0..38)
                               mode = mode(random)
                               {"rescale #{mode}", outcome { a.rescale(scale, mode) }, oracle_rescale(big_a, scale, mode)}
                             when 7
                               comparison = (a <=> b)
                               equal_hash = a == b ? (a.hash == b.hash) : true
                               {"compare", "#{comparison} #{a == b} #{equal_hash}", "#{big_a <=> big_b} #{big_a == big_b} true"}
                             else
                               if random.rand(2) == 0
                                 text, natural_scale = exponent_text(random)
                                 parsed = outcome { Decimal.parse(text) }
                                 round_trip = parsed.includes?("Error") ? parsed : outcome { Decimal.parse(parsed).to_s }
                                 {"parse exponent", "#{parsed} #{round_trip}", "#{oracle_parse(text, natural_scale)} #{oracle_parse(text, natural_scale)}"}
                               else
                                 {"parse/to_s", "#{a} #{Decimal.parse(a.to_s)}", "#{text_a} #{text_a}"}
                               end
                             end
      counts[name.split(' ').first] += 1
      errors[expected] += 1 if expected.ends_with?("Error")
      next if ours == expected
      differences += 1
      if differences <= 20
        puts "DIFFERENCE ##{index} #{name}: a=#{text_a} b=#{text_b}\n  mica:   #{ours}\n  oracle: #{expected}"
      end
    end
    puts "seed #{seed}, #{operations} operations"
    counts.to_a.sort!.each { |name, count| puts "  #{name.ljust(16)} #{count}" }
    puts "oracle error outcomes (each matched by Mica raising the same error):"
    errors.to_a.sort!.each { |name, count| puts "  #{name.ljust(20)} #{count}" }
    puts "differences: #{differences}"
    differences
  end
end

seed = (ARGV[0]? || "20261127").to_u64
operations = (ARGV[1]? || "1000000").to_i32
exit(DecimalDifferential.run(seed, operations) == 0 ? 0 : 1)
