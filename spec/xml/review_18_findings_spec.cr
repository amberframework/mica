require "../spec_helper"

# Regression specs for the eighteenth Codex code review of 2026-10-24.
describe "Codex review 18 findings" do
  it "1: points an initial input-size error past a byte order mark and line ends" do
    bom = Bytes[0xEF_u8, 0xBB_u8, 0xBF_u8]
    error = expect_raises(Mica::LimitExceededError) do
      Mica::XML.parse(bom + "<r/>".to_slice, Mica::XML::ParserOptions.new(max_input_bytes: 3_i64))
    end
    error.byte_offset.should eq(6)
    error = expect_raises(Mica::LimitExceededError) do
      Mica::XML.parse("<r>\n\nab</r>", Mica::XML::ParserOptions.new(max_input_bytes: 6_i64))
    end
    error.byte_offset.should eq(6)
    error.position.line.should eq(3)
    error.position.column.should eq(2)
  end

  it "2: points a refill's input-size error at the first byte past the limit" do
    error = expect_raises(Mica::LimitExceededError) do
      Mica::XML.parse(IO::Memory.new("<r>ab</r>"), Mica::XML::ParserOptions.new(max_input_bytes: 5_i64))
    end
    error.byte_offset.should eq(5)
  end

  it "3 and 5: charges serializing an expanded subtree before it writes" do
    children = "<c/>" * 1_000
    xml = "<r><e>#{children}</e></r>"
    probe = Mica::XML::Reader.new(xml)
    probe.read
    probe.read
    probe.expand
    expanded = probe.operations
    budget = Mica::Core::WorkBudget.new(operations_per_unit: 0, base_operations: expanded + 10, max_operations: expanded + 10)
    reader = Mica::XML::Reader.new(xml, Mica::XML::ParserOptions.new(work_budget: budget))
    reader.read
    reader.read
    expect_raises(Mica::WorkBudgetExceededError) { reader.read_inner_xml }
    reader.operations.should be <= expanded + 10 + "<c/>".bytesize
  end

  it "4: keeps a document's namespace mode fixed" do
    Mica::XML::Document.new.responds_to?(:namespace_aware=).should be_false
  end
end
