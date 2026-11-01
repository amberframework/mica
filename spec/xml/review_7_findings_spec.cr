require "../spec_helper"

private CHECKED_11 = Mica::XML::ParserOptions.new(check_normalization: true)

# Regression specs for the seventh Codex code review of 2026-10-24.
describe "Codex review 7 findings" do
  it "1: decides once, at compile time, whether a step's predicates use the position" do
    document = Mica::XML.parse("<r>#{"<e/>" * 20_000}</r>")
    arguments = (1..2_000).join(", ") { "'x'" }
    expression = Mica::XML::XPath.compile("//e[z[concat(#{arguments}) = 'y']]")
    started = Time.instant
    expression.evaluate(root_of(document)).as(Mica::XML::NodeSet).size.should eq(0)
    (Time.instant - started).should be < 1.second
  end

  it "2: charges comparing an existing namespace declaration in place" do
    uri = "urn:#{"u" * 10_000}"
    document = Mica::XML.parse("<r xmlns:p='#{uri}'><p:x/></r>")
    root = root_of(document)
    meter = document.edit_meter
    before = meter.operations
    10.times { expect_raises(Mica::Error, /not supported/) { root["xmlns:p"] = "x" } }
    (meter.operations - before).should be >= 10 * "x".bytesize
    root["xmlns:p"] = uri
  end

  it "3: charges the declaration's URI when an unlink is refused" do
    uri = "urn:#{"u" * 10_000}"
    document = Mica::XML.parse("<r xmlns='#{uri}'><x/></r>")
    declaration = (0...document.node_count).map { |index| document.node_at(index) }.find!(&.type.namespace_decl?)
    meter = document.edit_meter
    before = meter.operations
    10.times { expect_raises(Mica::Error, /unbind/) { declaration.unlink } }
    (meter.operations - before).should be >= 10 * uri.bytesize
  end

  it "4: charges rehashes caused by editing an expanded subtree to the edit meter" do
    reader = Mica::XML::Reader.new("<r><e/><f/></r>")
    reader.read
    reader.read
    element = reader.expand
    reader_operations = reader.operations
    5_000.times { |number| element["n#{number}"] = "1" }
    reader.operations.should eq(reader_operations)
    element.document.edit_meter.operations.should be > 5_000
  end

  it "5: points element, attribute and PI name errors at the offending character" do
    {
      "<?xml version='1.1'?><é/>"             => 23,
      "<?xml version='1.1'?><r á='1'/>"       => 25,
      "<?xml version='1.1'?><r b='2' á='1'/>" => 31,
      "<?xml version='1.1'?><r/><?ṕ x?>"      => 28,
    }.each do |xml, offset|
      error = expect_raises(Mica::XML::NormalizationError) { Mica::XML.parse(xml, CHECKED_11) }
      error.byte_offset.should eq(offset)
    end
  end
end
