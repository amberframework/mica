require "../spec_helper"

private CHECKED_11 = Mica::XML::ParserOptions.new(check_normalization: true)

private def tight_meter(operations : Int) : Mica::Core::WorkMeter
  Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.new(operations_per_unit: 0, base_operations: operations, max_operations: operations))
end

# Regression specs for the fifth Codex code review of 2026-10-24.
describe "Codex review 5 findings" do
  it "1: charges hashing the document element's namespace prefixes" do
    declarations = (1..2_000).join(" ") { |number| "xmlns:#{"p" * 200}#{number}='u'" }
    document = Mica::XML.parse("<r #{declarations}/>")
    expression = Mica::XML::XPath.compile("1", Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited))
    meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
    expression.evaluate(root_of(document), meter: meter)
    meter.operations.should be >= 2_000 * 200
  end

  it "2-4: stops an edit sequence that would do superlinear work with a WorkBudgetExceededError" do
    count = 3_000
    descendants = (1..count).join { |number| "<d xmlns:p#{number}='u'><p#{number}:x/></d>" }
    document = Mica::XML.parse("<r>#{descendants}</r>")
    root = root_of(document)
    started = Time.instant
    expect_raises(Mica::WorkBudgetExceededError, /editing the document/) do
      (1..count).each { |number| root["xmlns:p#{number}"] = "u" }
    end
    (Time.instant - started).should be < 10.seconds
    document.renew_edit_meter(Mica::Core::WorkBudget.unlimited)
    root["xmlns:p#{count}"] = "u"
    root.namespace_definitions.map(&.prefix).should contain("p#{count}")
  end

  it "2-4: charges deep prefix resolutions to the edit meter" do
    depth = 4_000
    options = Mica::XML::ParserOptions.new(max_element_depth: depth + 10)
    document = Mica::XML.parse("<r xmlns:p='urn:p'>#{"<e>" * depth}#{"</e>" * depth}</r>", options)
    deepest = document.xpath_nodes("//e[not(e)]").first
    expect_raises(Mica::WorkBudgetExceededError) do
      depth.times { |number| deepest["p:a#{number}"] = "1" }
    end
  end

  it "5: gives local-name() the whole name in a document read without namespaces" do
    document = Mica::XML.parse("<r><p:long_name/></r>", Mica::XML::ParserOptions.new(namespace_aware: false))
    document.xpath_string("local-name(/*/*)").should eq("p:long_name")
  end

  it "6: matches processing-instruction targets by name id" do
    document = Mica::XML.parse("<r><?t a?><?u b?><?t c?></r>")
    document.xpath_float("count(//processing-instruction('t'))").should eq(2.0)
    document.xpath_float("count(//processing-instruction('v'))").should eq(0.0)
    document.xpath_float("count(//processing-instruction())").should eq(3.0)
  end

  it "7: checks composition against a class-0 composing character as the new starter" do
    error = expect_raises(Mica::XML::NormalizationError) do
      Mica::XML.parse("<?xml version='1.1'?><a>q\u{113C2}\u{113B8}</a>", CHECKED_11)
    end
    error.byte_offset.should eq(29)
  end

  it "8: positions a DTD name error when the stream buffer compacts past its first 64 KiB" do
    (65_490..65_540).step(7).each do |padding|
      xml = "<?xml version='1.1'?><!--#{"x" * padding}--><!DOCTYPE r [<!ELEMENT é EMPTY>]><r/>"
      error = expect_raises(Mica::XML::NormalizationError) do
        Mica::XML.parse(TrickleIO.new(xml.to_slice, 1), CHECKED_11)
      end
      error.byte_offset.should eq(xml.byte_index("́"))
    end
  end
end
