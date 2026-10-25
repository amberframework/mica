require "../spec_helper"

# Regression specs for the fourteenth Codex code review of 2026-10-24.
describe "Codex review 14 findings" do
  long = "a" * 1_000_000

  it "1: quotes a short excerpt of an undefined variable or prefix and charges the variable lookup" do
    document = Mica::XML.parse("<r/>")
    error = expect_raises(Mica::XML::XPathError, /Undefined XPath variable/) { document.xpath_float("$#{long}") }
    (error.message || "").bytesize.should be < 600
    error = expect_raises(Mica::XML::XPathError, /Undefined namespace prefix/) { document.xpath_nodes("//#{long}:x") }
    (error.message || "").bytesize.should be < 600
    meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
    expect_raises(Mica::XML::XPathError) { document.xpath_float("$#{long}", meter: meter) }
    meter.operations.should be >= long.bytesize
  end

  it "2: charges translate()'s replacement string" do
    document = Mica::XML.parse("<r/>")
    replacement = "\u00e9" * 100_000
    meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
    document.xpath_string("translate('ab', 'ab', '#{replacement}')", meter: meter).should eq("\u00e9\u00e9")
    # Lexing charges one per character; translate() charges the bytes.
    meter.operations.should be >= replacement.size + replacement.bytesize
  end

  it "3: charges a mismatched end tag and quotes a short excerpt of it" do
    error = expect_raises(Mica::ParseError, /does not match/) { Mica::XML.parse("<a></#{"b" * 20_000}>") }
    (error.message || "").bytesize.should be < 600
  end

  it "4: quotes a short excerpt of an invalid builder name" do
    error = expect_raises(Mica::Error, /Invalid/) do
      Mica::XML.build { |xml| xml.element("!#{long}") { } }
    end
    (error.message || "").bytesize.should be < 600
  end
end
