require "../spec_helper"

# Regression specs for the twenty-fourth Codex code review of 2026-10-24.
describe "Codex review 24 findings" do
  it "1: charges a long namespace URI before interning it" do
    uri = "urn:#{"u" * 100_000}"
    meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
    Mica::XML.parse("<r xmlns='#{uri}'/>", meter: meter)
    meter.operations.should be >= 3 * uri.bytesize
  end

  it "2: charges carrying buffered bytes into a transcoder" do
    body = "<r>#{"t" * 50_000}</r>"
    latin = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
    Mica::XML.parse(IO::Memory.new("<?xml version='1.0' encoding='ISO-8859-1'?>#{body}"), meter: latin)
    utf8 = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
    Mica::XML.parse(IO::Memory.new("<?xml version='1.0' encoding='UTF-8'?>#{body}"), meter: utf8)
    (latin.operations - utf8.operations).should be >= body.bytesize
  end

  it "3 and 5: charges attribute values and node-set comparisons in XPath" do
    value = "v" * 100_000
    document = Mica::XML.parse("<r a='#{value}' b='#{value}'/>")
    meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
    document.xpath_bool("//@a = //@b", meter: meter).should be_true
    meter.operations.should be >= 4 * value.bytesize
    meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
    document.xpath_bool("//@a < //@b", meter: meter).should be_false
    meter.operations.should be >= 4 * value.bytesize
  end
end
