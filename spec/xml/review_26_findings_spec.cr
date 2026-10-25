require "../spec_helper"

# Regression specs for the twenty-sixth Codex code review of 2026-10-24.
describe "Codex review 26 findings" do
  it "1: charges the names of DTD-defaulted attributes before the namespace pass" do
    names = (1..100).map { |number| "a#{number}#{"n" * 1_000}" }
    declarations = names.join { |name| "<!ATTLIST r #{name} CDATA 'v'>" }
    meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
    Mica::XML.parse("<!DOCTYPE r [#{declarations}]><r/>", meter: meter)
    meter.operations.should be >= 3 * names.sum(&.bytesize)
  end

  it "2: charges both URI passes when an unlink is checked" do
    uri = "urn:#{"u" * 10_000}"
    document = Mica::XML.parse("<r xmlns:p='#{uri}'><c xmlns:p='#{uri}'/></r>")
    declaration = (0...document.node_count).map { |index| document.node_at(index) }.reverse_each.find!(&.type.namespace_decl?)
    meter = document.edit_meter
    before = meter.operations
    declaration.unlink
    (meter.operations - before).should be >= 2 * uri.bytesize
  end

  it "4: charges the delimiter scan of comment content" do
    document = Mica::XML.parse("<r><!--c--></r>")
    comment = node_at(document, "/r/comment()")
    text = "c" * 100_000
    meter = document.edit_meter
    before = meter.operations
    comment.content = text
    (meter.operations - before).should be >= 3 * text.bytesize
  end

  it "5: charges both passes of a reader attribute lookup" do
    reader = Mica::XML::Reader.new("<r/>")
    reader.read
    name = "n" * 100_000
    before = reader.operations
    reader[name]?.should be_nil
    (reader.operations - before).should be >= 2 * name.bytesize
  end
end
