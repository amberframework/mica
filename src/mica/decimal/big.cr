require "big"
require "../decimal"

# `BigDecimal` conversions for `Mica::Decimal128` (opt-in: `require
# "mica/decimal/big"`). This is the only Mica decimal file that requires
# "big", so only programs that load it link libgmp.
#
# ```
# Mica::Decimal128.parse("12.30").to_big_d           # => 12.3
# Mica::Decimal128.new(BigDecimal.new("12.30")).to_s # => "12.3"
# ```
module Mica
  struct Decimal128
    # Converts *value* exactly, keeping its scale where 38 digits allow. A
    # value with more digits or a scale above 38 gives up trailing zeros
    # first; raises `OverflowError` when the exact value still needs more
    # than 38 digits or a scale above 38.
    def self.new(value : BigDecimal) : Decimal128
      coefficient = value.value
      scale = value.scale.to_i64
      wanted_scale = Math.min(scale, MAX_SCALE.to_i64)
      while scale > 0 && coefficient != 0 && coefficient % 10 == 0
        coefficient = coefficient.tdiv(10)
        scale -= 1
      end
      scale = 0_i64 if coefficient == 0
      if scale > MAX_SCALE || coefficient.abs > MAX_COEFFICIENT
        raise OverflowError.new("#{value} needs more than #{MAX_DIGITS} digits or a scale above #{MAX_SCALE}")
      end
      result = Decimal128.new(coefficient.to_i128, scale.to_i32)
      room = MAX_DIGITS - result.precision
      room = MAX_DIGITS if result.zero?
      result.rescale(Math.min(wanted_scale, scale + room).to_i32)
    end

    # Returns the same value as a `BigDecimal`, at the same scale.
    def to_big_d : BigDecimal
      BigDecimal.new(BigInt.new(@coefficient), @scale.to_u64)
    end
  end
end
