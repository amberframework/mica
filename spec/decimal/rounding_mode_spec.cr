require "./support"

# The documented table: each mode on 2.5, -2.5, 2.4, -2.6, 2.6 and -2.4.
private ROUNDING_TABLE = {
  Mica::Decimal128::RoundingMode::TiesAway => {"3", "-3", "2", "-3", "3", "-2"},
  Mica::Decimal128::RoundingMode::TiesEven => {"2", "-2", "2", "-3", "3", "-2"},
  Mica::Decimal128::RoundingMode::Floor    => {"2", "-3", "2", "-3", "2", "-3"},
  Mica::Decimal128::RoundingMode::Ceiling  => {"3", "-2", "3", "-2", "3", "-2"},
  Mica::Decimal128::RoundingMode::Truncate => {"2", "-2", "2", "-2", "2", "-2"},
}

private INPUTS = {"2.5", "-2.5", "2.4", "-2.6", "2.6", "-2.4"}

describe Mica::Decimal128::RoundingMode do
  it_satisfies "DECIMAL-ROUNDING-MODES", "rounds positive and negative ties and non-ties as named" do
    ROUNDING_TABLE.each do |mode, expected|
      INPUTS.each_with_index do |input, index|
        dec(input).round(0, mode).to_s.should eq expected[index]
        dec(input).rescale(0, mode).to_s.should eq expected[index]
        # The same through division: input * 2 / 2.
        (dec(input) * dec("2")).divide(dec("2"), 0, mode).to_s.should eq expected[index]
      end
    end
  end

  it_satisfies "DECIMAL-ROUNDING-MODES", "rounds ties to even on odd and even last digits" do
    dec("3.5").round(0, :ties_even).to_s.should eq "4"
    dec("-3.5").round(0, :ties_even).to_s.should eq "-4"
    dec("0.125").round(2, :ties_even).to_s.should eq "0.12"
    dec("0.135").round(2, :ties_even).to_s.should eq "0.14"
    dec("0.1250001").round(2, :ties_even).to_s.should eq "0.13"
    dec("-0.1250001").round(2, :ties_even).to_s.should eq "-0.13"
  end

  it_satisfies "DECIMAL-ROUNDING-MODES", "rounds ties on 38-digit coefficients" do
    dec("1234567890123456789012345678901234567.5").round(0, :ties_even).to_s.should eq "1234567890123456789012345678901234568"
    dec("-1234567890123456789012345678901234566.5").round(0, :ties_even).to_s.should eq "-1234567890123456789012345678901234566"
    dec("-1234567890123456789012345678901234566.5").round(0, :ties_away).to_s.should eq "-1234567890123456789012345678901234567"
    dec("0.#{"5" * 38}").round(0, :ties_away).to_s.should eq "1"
    dec("-0.#{"4" * 38}").round(0, :floor).to_s.should eq "-1"
  end

  it_satisfies "DECIMAL-ROUNDING-MODES", "raises InexactError for Unnecessary only when a nonzero digit would go" do
    INPUTS.each do |input|
      expect_raises(Mica::Decimal128::InexactError) { dec(input).round(0, :unnecessary) }
    end
    dec("2.50").round(1, :unnecessary).to_s.should eq "2.5"
    dec("-2.00").round(0, :unnecessary).to_s.should eq "-2"
  end
end
