# The control for minimal_decimal.cr: the same values through
# `require "mica/decimal/big"`, which requires the standard library's
# "big". scripts/check_linkage.sh expects libgmp in every probe of this
# binary, which proves the probes would catch it in minimal_decimal.
require "../../src/mica/decimal/big"

price = Mica::Decimal128.parse(ARGV[0]? || "19.99")
puts price.to_big_d * BigDecimal.new("0.0825")
