require "./support"

private def usd(text : String) : Mica::Money
  Mica::Money.new(text, "USD")
end

private def strings(list : Array(Mica::Money)) : Array(String)
  list.map(&.to_s)
end

describe Mica::Money do
  it_satisfies "MONEY-NEW", "takes a Decimal128, String or Int amount and a Currency or code" do
    Mica::Money.new(dec("12.30"), Mica::Currency.find("USD")).to_s.should eq "12.30 USD"
    Mica::Money.new("12.30", "USD").amount.should eq dec("12.30")
    Mica::Money.new(12, "JPY").to_s.should eq "12 JPY"
    Mica::Money.new(12, "USD").currency.minor_units.should eq 2
    expect_raises(Mica::Currency::UnknownError) { Mica::Money.new(1, "ZZZ") }
    expect_raises(Mica::Decimal128::ParseError) { Mica::Money.new("12,30", "USD") }
  end

  it_satisfies "MONEY-ADD-SUB", "adds and subtracts equal currencies and refuses others" do
    (usd("0.10") + usd("0.20")).should eq usd("0.30")
    (usd("10.00") - usd("0.01")).to_s.should eq "9.99 USD"
    (-usd("1.50")).to_s.should eq "-1.50 USD"
    expect_raises(Mica::Money::CurrencyMismatchError, "cannot add EUR and USD") { usd("1") + Mica::Money.new(1, "EUR") }
    expect_raises(Mica::Money::CurrencyMismatchError) { usd("1") - Mica::Money.new(1, "EUR") }
    Mica::Money::CurrencyMismatchError.new.is_a?(Mica::Money::Error).should be_true
  end

  it_satisfies "MONEY-MUL", "multiplies by a Decimal128 or an Int exactly" do
    (usd("19.99") * dec("1.07")).to_s.should eq "21.3893 USD"
    (usd("19.99") * 3).to_s.should eq "59.97 USD"
    expect_raises(Mica::Decimal128::OverflowError) { usd(NINES_38) * 2 }
  end

  it_satisfies "MONEY-ROUND", "rounds to the currency's minor units" do
    (usd("19.99") * dec("1.07")).round(:ties_away).to_s.should eq "21.39 USD"
    usd("2.345").round(:ties_even).to_s.should eq "2.34 USD"
    usd("-2.345").round(:ties_away).to_s.should eq "-2.35 USD"
    usd("12.3").round(:unnecessary).to_s.should eq "12.30 USD"
    Mica::Money.new("1234.5", "JPY").round(:ties_even).to_s.should eq "1234 JPY"
    Mica::Money.new("1.23456", "BHD").round(:floor).to_s.should eq "1.234 BHD"
    expect_raises(Mica::Decimal128::InexactError) { usd("2.345").round(:unnecessary) }
    expect_raises(Mica::Currency::NoMinorUnitsError) { Mica::Money.new(1, "XAU").round(:ties_even) }
  end

  it_satisfies "MONEY-ALLOCATE", "allocates by ratio without losing or inventing a minor unit" do
    strings(usd("100.00").allocate([70, 20, 10])).should eq ["70.00 USD", "20.00 USD", "10.00 USD"]
    strings(usd("0.05").allocate([3, 7])).should eq ["0.02 USD", "0.03 USD"]
    strings(usd("0.05").allocate([1, 0, 1])).should eq ["0.03 USD", "0.00 USD", "0.02 USD"]
    strings(usd("-0.05").allocate([1, 1])).should eq ["-0.03 USD", "-0.02 USD"]
    strings(usd("10").allocate([1, 2])).should eq ["3.33 USD", "6.67 USD"]
    strings(usd("0.00").allocate([1, 1])).should eq ["0.00 USD", "0.00 USD"]
    huge = usd("#{"9" * 36}.99")
    huge_parts = huge.allocate([Int64::MAX, 1, Int64::MAX])
    (huge_parts[0] + huge_parts[1] + huge_parts[2]).should eq huge
    (huge_parts[0].amount - huge_parts[2].amount).abs.should be <= dec("0.01")
    random = Random.new(20261127)
    200.times do
      amount = Mica::Decimal128.new(random.rand(-10_000_000..10_000_000), 2)
      ratios = Array.new(random.rand(1..7)) { random.rand(0..50) }
      ratios[0] = 1 if ratios.sum == 0
      parts = Mica::Money.new(amount, "USD").allocate(ratios)
      parts.size.should eq ratios.size
      parts.reduce(Mica::Decimal128.zero(2)) { |sum, part| sum + part.amount }.should eq amount
      parts.each_with_index do |part, index|
        part.amount.scale.should eq 2
        part.amount.zero?.should be_true if ratios[index] == 0
      end
    end
  end

  it_satisfies "MONEY-ALLOCATE", "requires an amount at the minor units and sensible ratios" do
    expect_raises(Mica::Decimal128::InexactError) { usd("0.005").allocate([1, 1]) }
    expect_raises(ArgumentError) { usd("1").allocate([] of Int32) }
    expect_raises(ArgumentError) { usd("1").allocate([1, -1]) }
    expect_raises(ArgumentError) { usd("1").allocate([0, 0]) }
  end

  it_satisfies "MONEY-SPLIT", "splits 100.00 USD into 33.34, 33.33 and 33.33" do
    parts = usd("100.00").split(3)
    strings(parts).should eq ["33.34 USD", "33.33 USD", "33.33 USD"]
    parts.reduce { |sum, part| sum + part }.should eq usd("100.00")
    strings(Mica::Money.new(100, "JPY").split(3)).should eq ["34 JPY", "33 JPY", "33 JPY"]
    strings(Mica::Money.new("1.000", "BHD").split(3)).should eq ["0.334 BHD", "0.333 BHD", "0.333 BHD"]
    strings(Mica::Money.new("10", "BHD").split(4)).should eq ["2.500 BHD", "2.500 BHD", "2.500 BHD", "2.500 BHD"]
    strings(usd("0.01").split(3)).should eq ["0.01 USD", "0.00 USD", "0.00 USD"]
    strings(usd("#{NINES_38[0, 36]}.99").split(1)).should eq ["#{NINES_38[0, 36]}.99 USD"]
    expect_raises(ArgumentError) { usd("1").split(0) }
    expect_raises(Mica::Decimal128::InexactError) { Mica::Money.new("1.5", "JPY").split(2) }
  end

  it_satisfies "MONEY-TO-S", "writes the plain amount and the code" do
    usd("12.30").to_s.should eq "12.30 USD"
    usd("-0.05").inspect.should eq "-0.05 USD"
    Mica::Money.new("1234567.891", "BHD").to_s.should eq "1234567.891 BHD"
  end

  it_satisfies "MONEY-EQUALITY", "compares and hashes by amount value and currency" do
    (usd("12.3") == usd("12.30")).should be_true
    usd("12.3").hash.should eq usd("12.30").hash
    (usd("1") == Mica::Money.new(1, "EUR")).should be_false
    {usd("1.0") => 1}[usd("1")]?.should eq 1
  end
end
