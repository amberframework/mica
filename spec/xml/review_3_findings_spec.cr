require "../spec_helper"

private CHECKED_11 = Mica::XML::ParserOptions.new(check_normalization: true)

private def tight_meter(operations : Int) : Mica::Core::WorkMeter
  Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.new(operations_per_unit: 0, base_operations: operations, max_operations: operations))
end

# Regression specs for the third Codex code review of 2026-10-24.
describe "Codex review 3 findings" do
  it "1: calls the transcoder's read hook after every source read" do
    source = utf16("<r>#{"x" * 1_000}</r>", big_endian: true)
    transcoder = Mica::Core::Transcoder.new(TrickleIO.new(source[2, source.size - 2], 1), Mica::Core::Encoding::UTF16BE)
    reads = 0
    transcoder.after_source_read = -> { reads += 1; nil }
    buffer = Bytes.new(64 * 1024)
    while transcoder.read(buffer) > 0
    end
    reads.should be >= source.size - 2
  end

  it "2: holds every digit of a character reference to the token limit" do
    options = Mica::XML::ParserOptions.new(max_token_bytes: 16)
    expect_raises(Mica::LimitExceededError) { Mica::XML.parse("<r>&##{"0" * 100}65;</r>", options) }
  end

  it "3: charges an XPath name lookup before hashing the name" do
    document = Mica::XML.parse("<r/>")
    expression = Mica::XML::XPath.compile("//#{"a" * 100_000}", Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited))
    expect_raises(Mica::WorkBudgetExceededError) { expression.evaluate(root_of(document), meter: tight_meter(1_000)) }
  end

  it "5: checks the element name of an ATTLIST without attribute definitions" do
    xml = "<?xml version='1.1'?><!DOCTYPE r [<!ATTLIST é>]><r/>"
    expect_raises(Mica::XML::NormalizationError) { Mica::XML.parse(xml, CHECKED_11) }
  end

  it "6: deletes many attributes in linear time" do
    count = 50_000
    document = Mica::XML.parse("<r/>")
    root = root_of(document)
    count.times { |number| root["a#{number}"] = number.to_s }
    started = Time.instant
    count.times { |number| root.delete("a#{number}").should eq(number.to_s) }
    (Time.instant - started).should be < 2.seconds
    root.attributes.size.should eq(0)
  end

  it "7: resolves the prefix of many new attributes on an edited element in linear time" do
    count = 20_000
    document = Mica::XML.parse("<r xmlns:p='urn:p'><c/></r>")
    child = node_at(document, "/r/c")
    started = Time.instant
    count.times { |number| child["p:a#{number}"] = number.to_s }
    (Time.instant - started).should be < 2.seconds
    document.xpath_string("string(/r/c/@p:a#{count - 1})", {"p" => "urn:p"}).should eq((count - 1).to_s)
  end

  it "8: blames the combining character that first breaks NFC" do
    error = expect_raises(Mica::XML::NormalizationError) do
      Mica::XML.parse("<?xml version='1.1'?><a>q̀̕</a>", CHECKED_11)
    end
    error.byte_offset.should eq(27)
  end

  it "9: points a DTD name's normalization error into the name" do
    error = expect_raises(Mica::XML::NormalizationError) do
      Mica::XML.parse("<?xml version='1.1'?><!DOCTYPE r [<!ELEMENT é EMPTY>]><r/>", CHECKED_11)
    end
    error.byte_offset.should eq(45)
    error.position.column.should eq(46)
  end

  it "10: reports reseed and rebuild work once, before it runs" do
    table = Mica::XML::NameTable.new
    reported = 0_i64
    table.before_rebuild = ->(work : Int64) { reported += work; nil }
    last = table.unpaid_operations
    10_000.times do |number|
      table.intern("n#{number}")
      table.unpaid_operations.should be >= last
      last = table.unpaid_operations
    end
    reported.should be > 0
    table.prepaid_operations.should eq(reported)
  end
end
