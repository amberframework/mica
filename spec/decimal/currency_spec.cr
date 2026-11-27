require "./support"

describe Mica::Currency do
  it_satisfies "CURRENCY-TABLE", "holds every current ISO 4217 code with its numeric code and minor units" do
    Mica::Currency::TABLE.size.should eq 178
    Mica::Currency::TABLE_PUBLISHED.should eq "2026-09-17"
    {
      "USD" => {840, 2}, "EUR" => {978, 2}, "JPY" => {392, 0}, "BHD" => {48, 3},
      "KWD" => {414, 3}, "CLF" => {990, 4}, "UYW" => {927, 4}, "ISK" => {352, 0}, "ALL" => {8, 2},
    }.each do |code, (numeric_code, minor_units)|
      currency = Mica::Currency.find(code)
      currency.code.should eq code
      currency.numeric_code.should eq numeric_code
      currency.minor_units.should eq minor_units
    end
    Mica::Currency.all.map(&.code).should eq Mica::Currency::TABLE.keys.sort
    Mica::Currency.all.each { |currency| currency.code.should match(/\A[A-Z]{3}\z/) }
  end

  it_satisfies "CURRENCY-TABLE", "gives codes without a minor unit none" do
    gold = Mica::Currency.find("XAU")
    gold.minor_units?.should be_nil
    expect_raises(Mica::Currency::NoMinorUnitsError) { gold.minor_units }
    Mica::Currency.find("USD").minor_units?.should eq 2
  end

  it_satisfies "CURRENCY-FIND", "finds a code or raises UnknownError" do
    Mica::Currency.find?("ZZZ").should be_nil
    Mica::Currency.find?("usd").should be_nil
    expect_raises(Mica::Currency::UnknownError, %("ZZZ" is not a current ISO 4217 currency code)) { Mica::Currency.find("ZZZ") }
    Mica::Currency::UnknownError.new.is_a?(Mica::Currency::Error).should be_true
    Mica::Currency.find("USD").should eq Mica::Currency.find("USD")
    Mica::Currency.find("USD").to_s.should eq "USD"
  end
end
