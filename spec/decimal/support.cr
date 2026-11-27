require "../spec_helper"

private alias Decimal = Mica::Decimal128

# Parses *text* as a Decimal128.
def dec(text : String) : Mica::Decimal128
  Mica::Decimal128.parse(text)
end

# The largest coefficient, 38 nines.
NINES_38 = "9" * 38
