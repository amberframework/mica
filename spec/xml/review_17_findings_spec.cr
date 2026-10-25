require "../spec_helper"

private UNAWARE = Mica::XML::ParserOptions.new(namespace_aware: false)

# Regression specs for the seventeenth Codex code review of 2026-10-24.
describe "Codex review 17 findings" do
  it "1: checks the budget while scanning a long XML declaration value" do
    budget = Mica::Core::WorkBudget.new(operations_per_unit: 0, base_operations: 1_000, max_operations: 1_000)
    xml = "<?xml version='1.#{"0" * 1_000_000}x'?><r/>"
    expect_raises(Mica::WorkBudgetExceededError) do
      Mica::XML.parse(xml, Mica::XML::ParserOptions.new(work_budget: budget))
    end
  end

  it "2: stops serializing an expanded subtree when the budget runs out" do
    text = "t" * 200_000
    budget = Mica::Core::WorkBudget.new(operations_per_unit: 1, base_operations: 0)
    reader = Mica::XML::Reader.new("<r><e a='1'>#{text}</e></r>", Mica::XML::ParserOptions.new(work_budget: budget))
    reader.read
    reader.read
    expect_raises(Mica::WorkBudgetExceededError) { reader.read_outer_xml }
  end

  it "3: edits whole names without namespace processing" do
    document = Mica::XML.parse("<a:b:c/>", UNAWARE)
    root = root_of(document)
    root.name = "x:y:z"
    root.name.should eq("x:y:z")
    root["xmlns"] = "plain"
    root["q:w"] = "1"
    root["xmlns"]?.should eq("plain")
    root["q:w"]?.should eq("1")
  end

  it "4: matches prefixed names whole in an XPath over a namespace-unaware document" do
    document = Mica::XML.parse("<r><p:a/><p:a/></r>", UNAWARE)
    document.xpath_nodes("//p:a").size.should eq(2)
  end

  it "5: counts the document's value bytes in the evaluation allowance" do
    document = Mica::XML.parse("<r>#{"t" * 1_200_000}</r>")
    document.xpath_string("string(/r)").bytesize.should eq(1_200_000)
  end

  it "6: reads an empty stream under an Int64::MAX input cap" do
    options = Mica::XML::ParserOptions.new(max_input_bytes: Int64::MAX)
    expect_raises(Mica::ParseError) { Mica::XML.parse(IO::Memory.new(""), options) }
    Mica::XML.parse(IO::Memory.new("<r/>"), options)
  end

  it "7: points an initial input-size error at the first byte past the limit" do
    error = expect_raises(Mica::LimitExceededError) do
      Mica::XML.parse("<r/>", Mica::XML::ParserOptions.new(max_input_bytes: 3_i64))
    end
    error.byte_offset.should eq(3)
  end
end
