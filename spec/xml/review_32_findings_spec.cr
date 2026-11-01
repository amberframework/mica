require "../spec_helper"

private def unlimited_meter : Mica::Core::WorkMeter
  Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
end

# Regression specs for the thirty-second Codex code review of 2026-10-24.
# Each threshold sits between the count measured before the fix and the
# count after it, so a lost charge fails the example.
describe "Codex review 32 findings" do
  it "2: charges each attribute definition's hash operations" do
    definitions = (1..5_000).join(' ') { |number| "a#{number} CDATA #IMPLIED" }
    meter = unlimited_meter
    Mica::XML.parse("<!DOCTYPE r [<!ATTLIST r #{definitions}>]><r/>", meter: meter)
    meter.operations.should be >= 345_000
  end

  it "4: charges translate()'s map operations" do
    document = Mica::XML.parse("<r/>")
    text = "a" * 10_000
    meter = unlimited_meter
    document.xpath_float("string-length(translate('#{text}', 'a', '\u{1F600}'))", meter: meter).should eq(10_000.0)
    meter.operations.should be >= 125_000
  end

  it "9: rejects an over-deep syntax tree and quotes an unknown function name" do
    leaf = Mica::XML::XPath::NumberExpr.new(1.0)
    deep = (1..300).reduce(leaf.as(Mica::XML::XPath::Expr)) do |inner, _|
      Mica::XML::XPath::FunctionCall.new("boolean", [inner] of Mica::XML::XPath::Expr).as(Mica::XML::XPath::Expr)
    end
    expect_raises(Mica::XML::XPathError, /nested too deeply/) { Mica::XML::XPath::Expression.new("x", deep) }
    name = "f" * 10_000
    unknown = Mica::XML::XPath::FunctionCall.new(name, [] of Mica::XML::XPath::Expr)
    error = expect_raises(Mica::XML::XPathError) do
      Mica::XML::XPath::Expression.new("x", unknown).evaluate(Mica::XML.parse("<r/>").root || fail("no root"))
    end
    (error.message || "").size.should be < 300
  end
end
