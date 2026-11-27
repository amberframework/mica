require "./support"
require "../../src/mica/decimal/json"
require "../../src/mica/decimal/yaml"
require "../../src/mica/decimal/big"

private struct Priced
  include JSON::Serializable
  include YAML::Serializable

  getter price : Mica::Decimal128
  getter discount : Mica::Decimal128?
end

describe "Mica::Decimal128 serialization" do
  it_satisfies "DECIMAL-JSON", "writes a JSON string and reads strings, integers and floats from their text" do
    dec("12.30").to_json.should eq %("12.30")
    [dec("-0.05"), dec("1")].to_json.should eq %(["-0.05","1"])
    Mica::Decimal128.from_json(%("12.30")).scale.should eq 2
    Mica::Decimal128.from_json(%(12.30)).to_s.should eq "12.30"
    Mica::Decimal128.from_json(%(-7)).to_s.should eq "-7"
    Mica::Decimal128.from_json(%(1.5e-3)).to_s.should eq "0.0015"
    Mica::Decimal128.from_json(%(0.1)).should eq dec("0.1")
    priced = Priced.from_json(%({"price": 19.99, "discount": "0.10"}))
    priced.price.to_s.should eq "19.99"
    priced.discount.to_s.should eq "0.10"
    Priced.from_json(priced.to_json).price.should eq dec("19.99")
    {dec("1.5") => 1}.to_json.should eq %({"1.5":1})
    expect_raises(JSON::ParseException) { Mica::Decimal128.from_json(%(true)) }
    expect_raises(Mica::Decimal128::ParseError) { Mica::Decimal128.from_json(%("12,30")) }
    expect_raises(Mica::Decimal128::OverflowError) { Mica::Decimal128.from_json(%(1e40)) }
  end

  it_satisfies "DECIMAL-YAML", "writes a plain scalar and reads it back with its scale" do
    dec("12.30").to_yaml.should eq "--- 12.30\n"
    Mica::Decimal128.from_yaml("12.30").scale.should eq 2
    Mica::Decimal128.from_yaml(%("-0.50")).to_s.should eq "-0.50"
    priced = Priced.from_yaml("price: 19.99\ndiscount: 0.10\n")
    Priced.from_yaml(priced.to_yaml).discount.to_s.should eq "0.10"
    expect_raises(YAML::ParseException) { Mica::Decimal128.from_yaml("[1]") }
    expect_raises(YAML::ParseException) { Mica::Decimal128.from_yaml("abc") }
  end

  it_satisfies "DECIMAL-BIG", "converts to and from BigDecimal exactly" do
    dec("12.30").to_big_d.should eq BigDecimal.new("12.30")
    dec("12.30").to_big_d.scale.should eq 2
    dec("-#{NINES_38}").to_big_d.should eq BigDecimal.new("-#{NINES_38}")
    Mica::Decimal128.new(BigDecimal.new("12.30")).to_s.should eq "12.30"
    Mica::Decimal128.new(BigDecimal.new("-0.000001")).to_s.should eq "-0.000001"
    Mica::Decimal128.new(BigDecimal.new(BigInt.new(10) ** 40, 40)).should eq dec("1")
    Mica::Decimal128.new(BigDecimal.new(BigInt.new(0), 50)).to_s.should eq "0.#{"0" * 38}"
    expect_raises(Mica::Decimal128::OverflowError) { Mica::Decimal128.new(BigDecimal.new("1#{NINES_38}")) }
    expect_raises(Mica::Decimal128::OverflowError) { Mica::Decimal128.new(BigDecimal.new(BigInt.new(1), 39)) }
  end
end
