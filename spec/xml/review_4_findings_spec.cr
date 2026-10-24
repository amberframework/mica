require "../spec_helper"

private CHECKED_11 = Mica::XML::ParserOptions.new(check_normalization: true)

private def tight_meter(operations : Int) : Mica::Core::WorkMeter
  Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.new(operations_per_unit: 0, base_operations: operations, max_operations: operations))
end

private def unlimited_meter : Mica::Core::WorkMeter
  Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
end

# Regression specs for the fourth Codex code review of 2026-10-24.
describe "Codex review 4 findings" do
  it "1: positions a DTD name's normalization error correctly when a refill moves the buffer mid-name" do
    xml = "<?xml version='1.1'?><!DOCTYPE r [<!ELEMENT é EMPTY>]><r/>"
    bytes = xml.to_slice
    offending = xml.byte_index("́") || raise "missing mark"
    (1..80).each do |chunk|
      error = expect_raises(Mica::XML::NormalizationError) do
        Mica::XML.parse(TrickleIO.new(bytes, chunk), CHECKED_11)
      end
      error.byte_offset.should eq(offending)
    end
  end

  it "2: charges an XPath prefix before looking it up" do
    prefix = "p" * 100_000
    document = Mica::XML.parse("<r/>")
    expression = Mica::XML::XPath.compile("//#{prefix}:a", unlimited_meter)
    expect_raises(Mica::WorkBudgetExceededError) do
      expression.evaluate(root_of(document), {prefix => "urn:p"}, meter: tight_meter(1_000))
    end
  end

  it "3: bounds every name-table lookup, present or absent, by the longest run" do
    table = Mica::XML::NameTable.new(7_u32)
    20_000.times { |number| table.intern("name#{number}") }
    1_000.times do |number|
      before = table.probes
      table.lookup("absent#{number}".to_slice).should eq(-1)
      (table.probes - before).should be <= Mica::XML::NameTable::MAX_RUN + 1
    end
  end

  it "4: matches whole names in a document read without namespaces" do
    document = Mica::XML.parse("<r><p:a/><a/></r>", Mica::XML::ParserOptions.new(namespace_aware: false))
    document.xpath_float("count(//a)").should eq(1.0)
    node_at(document, "/r/*[1]").qualified_name.should eq("p:a")
    document.xpath_float("count(//a)").should eq(1.0)
  end

  it "5: charges collecting the document element's namespaces" do
    declarations = (1..5_000).join(" ") { |number| "xmlns:p#{number}='urn:#{"u" * 100}#{number}'" }
    document = Mica::XML.parse("<r #{declarations}/>")
    expression = Mica::XML::XPath.compile("1", unlimited_meter)
    expect_raises(Mica::WorkBudgetExceededError) { expression.evaluate(root_of(document), meter: tight_meter(1_000)) }
  end

  it "6: resolves prefixes through parsed ancestors in linear time over many edits" do
    count = 20_000
    declarations = (1..2_000).join(" ") { |number| "xmlns:q#{number}='urn:q#{number}'" }
    document = Mica::XML.parse("<g xmlns:p='urn:p'><m #{declarations}><c/></m></g>")
    child = node_at(document, "/g/m/c")
    started = Time.instant
    count.times { |number| child["p:a#{number}"] = number.to_s }
    (Time.instant - started).should be < 2.seconds
  end

  it "7: deletes attributes by local name in linear time" do
    count = 20_000
    document = Mica::XML.parse("<r xmlns:p='urn:p'/>")
    root = root_of(document)
    count.times { |number| root["p:a#{number}"] = number.to_s }
    started = Time.instant
    (count - 1).downto(0) { |number| root.delete("a#{number}").should eq(number.to_s) }
    (Time.instant - started).should be < 2.seconds
    root.attributes.size.should eq(0)
  end

  it "8: declares many unused prefixes over a large subtree in linear time" do
    count = 20_000
    document = Mica::XML.parse("<r>#{"<e/>" * count}</r>")
    root = root_of(document)
    started = Time.instant
    count.times { |number| root["xmlns:n#{number}"] = "urn:n#{number}" }
    (Time.instant - started).should be < 2.seconds
    root.namespace_definitions.size.should eq(count)
  end

  it "9: blames the character that first breaks NFC after a long run of combining marks" do
    text = "q#{"̕" * 31}̀"
    error = expect_raises(Mica::XML::NormalizationError) do
      Mica::XML.parse("<?xml version='1.1'?><a>#{text}</a>", CHECKED_11)
    end
    error.byte_offset.should eq(24 + 1 + 31 * 2)
  end

  it "10: points a NOTATION enumeration name's normalization error into the name" do
    xml = "<?xml version='1.1'?><!DOCTYPE r [<!ATTLIST r t NOTATION (é) #IMPLIED>]><r/>"
    error = expect_raises(Mica::XML::NormalizationError) { Mica::XML.parse(xml, CHECKED_11) }
    error.byte_offset.should eq(xml.byte_index("́"))
  end
end
