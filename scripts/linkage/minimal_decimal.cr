# Uses Mica::Decimal128, Mica::Currency and Mica::Money through
# `require "mica/decimal"` alone: parse, arithmetic, division, rounding,
# comparison, hashing, to_s and a split. scripts/check_linkage.sh checks
# that it links no libgmp.
require "../../src/mica/decimal"

price = Mica::Decimal128.parse(ARGV[0]? || "19.99")
rate = Mica::Decimal128.parse("0.0825")
tax = (price * rate).round(2, :ties_away)
total = Mica::Money.new(price + tax, "USD")
share = price.divide(Mica::Decimal128.new(3), 4, :ties_even)
puts "#{total} #{share} #{price > tax} #{price.hash == Mica::Decimal128.parse("19.990").hash}"
puts total.split(3).join(" + ")
