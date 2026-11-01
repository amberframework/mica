require "../spec_helper"

private UNLIMITED = Mica::Core::WorkBudget.unlimited

private def tight_meter(operations : Int) : Mica::Core::WorkMeter
  Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.new(operations_per_unit: 0, base_operations: operations, max_operations: operations))
end

private def reader_operations(xml : String, options : Mica::XML::ParserOptions = Mica::XML::ParserOptions.default) : Int64
  meter = Mica::Core::WorkMeter.new(UNLIMITED)
  reader = Mica::XML::Reader.new(xml, options, meter)
  while reader.read
  end
  meter.operations
end

private def dom_operations(xml : String) : Int64
  meter = Mica::Core::WorkMeter.new(UNLIMITED)
  Mica::XML.parse(xml, Mica::XML::ParserOptions.default, meter)
  meter.operations
end

private CHECKED_11 = Mica::XML::ParserOptions.new(check_normalization: true)

# Regression specs for the second Codex code review of 2026-10-24.
describe "Codex review 2 findings" do
  it "1: charges the XPath lexer while it scans one long token, and compiles under a default budget" do
    path = "'#{"x" * 1_000_000}'"
    meter = tight_meter(10_000)
    expect_raises(Mica::WorkBudgetExceededError) { Mica::XML::XPath.compile(path, meter) }
    meter.operations.should be < 100_000
    Mica::XML::XPath.compile("count(//a)").should be_a(Mica::XML::XPath::Expression)
  end

  it "3: bounds a character reference's digit run by the token limit" do
    options = Mica::XML::ParserOptions.new(max_token_bytes: 4_096)
    expect_raises(Mica::LimitExceededError) do
      Mica::XML.parse("<a>&#x#{"0" * 100_000}41;</a>", options)
    end
  end

  it "4: stops a name at the first byte past max_name_bytes, also when the first character is wider" do
    options = Mica::XML::ParserOptions.new(max_name_bytes: 1)
    expect_raises(Mica::LimitExceededError) { Mica::XML.parse("<あa/>", options) }
    error = expect_raises(Mica::LimitExceededError) { Mica::XML.parse("<ab/>", options) }
    error.byte_offset.should eq(2)
  end

  it "6: reports name-table rebuild work before the table grows" do
    table = Mica::XML::NameTable.new
    sizes = [] of Int32
    table.before_rebuild = ->(work : Int64) do
      work.should be > 0
      sizes << table.size
      nil
    end
    10_000.times { |number| table.intern("n#{number}") }
    sizes.should_not be_empty
    sizes.each { |size| table.size.should be > size }
  end

  it "7: charges position mapping, and prepays the column fold of streamed input" do
    text = "x" * 300_000
    xml = "<a>#{text}<b/></a>"
    meter = Mica::Core::WorkMeter.new(UNLIMITED)
    reader = Mica::XML::Reader.new(xml, Mica::XML::ParserOptions.default, meter)
    reader.read
    reader.read
    reader.read
    before = meter.operations
    reader.position.column.should eq(8 + text.size)
    (meter.operations - before).should be >= text.size

    in_memory = reader_operations(xml)
    streamed_meter = Mica::Core::WorkMeter.new(UNLIMITED)
    streamed = Mica::XML::Reader.new(TrickleIO.new(xml.to_slice, 4_096), Mica::XML::ParserOptions.default, streamed_meter)
    while streamed.read
    end
    (streamed_meter.operations - in_memory).should be >= text.size // 2
  end

  it "8: charges the copies that merge adjacent text in the DOM" do
    prior = "x" * 100_000
    plain = dom_operations("<!DOCTYPE r [<!ENTITY e 'y<c/>'>]><r>#{prior}y<c/></r>")
    merged = dom_operations("<!DOCTYPE r [<!ENTITY e 'y<c/>'>]><r>#{prior}&e;</r>")
    (merged - plain).should be >= 2 * prior.size
  end

  it "9: charges the copy of inline text-only entity replacement text" do
    replacement = "y" * 10_000
    xml = "<!DOCTYPE r [<!ENTITY e '#{replacement}'>]><r>#{"&e;" * 10}</r>"
    reader_operations(xml).should be >= 10 * replacement.size
  end

  it "10: charges namespace binding pops before doing them" do
    declarations = (1..5_000).join(" ") { |number| "xmlns:p#{number}='u#{number}'" }
    reader = Mica::XML::Reader.new("<r><e #{declarations}/><f/></r>")
    reader.read
    reader.read
    reader.renew_meter(Mica::Core::WorkBudget.new(operations_per_unit: 0, base_operations: 0, max_operations: 0))
    expect_raises(Mica::WorkBudgetExceededError) { reader.read }
  end

  it "11: checks every DTD Name for XML 1.1 normalization, in unused declarations too" do
    decomposed = "é"
    {
      "<!ELEMENT #{decomposed} ANY>",
      "<!NOTATION #{decomposed} SYSTEM 'n'>",
      "<!ELEMENT r (#{decomposed})>",
      "<!ELEMENT r (#PCDATA | #{decomposed})*>",
      "<!ENTITY #{decomposed} SYSTEM 'x'>",
    }.each do |declaration|
      xml = "<?xml version='1.1'?><!DOCTYPE r [#{declaration}]><r/>"
      expect_raises(Mica::XML::NormalizationError) { Mica::XML.parse(xml, CHECKED_11) }
    end
    Mica::XML.parse("<?xml version='1.1'?><!DOCTYPE r [<!ELEMENT é ANY>]><r/>", CHECKED_11)
  end

  it "12: adds, renames and deletes many attributes in linear time" do
    document = Mica::XML.parse("<r a='0'/>")
    root = root_of(document)
    count = 50_000
    started = Time.instant
    count.times { |number| root["a#{number + 1}"] = number.to_s }
    (Time.instant - started).should be < 2.seconds
    root["a1"].should eq("0")
    root["a#{count}"].should eq((count - 1).to_s)
    root.delete("a#{count}").should eq((count - 1).to_s)
    root["z"] = "tail"
    root.attributes.to_a.last.name.should eq("z")
    attribute = root.attributes.to_a.find!(&.name.==("a2"))
    attribute.name = "b2"
    root["b2"].should eq("1")
    root["a2"]?.should be_nil
    expect_raises(Mica::Error, /already exists/) { attribute.name = "a3" }
    root_of(Mica::XML.parse(root.to_xml, Mica::XML::ParserOptions.new(max_attributes: 100_000))).attributes.size.should eq(count + 1)
  end

  it "13: counts the failure table before allocating it" do
    first = nil
    total = 0
    needle = ("a" * 50_000 + "b").to_slice
    Mica::Core::ByteSearch.index(Bytes.new(1), needle) { |steps| first ||= steps; total += steps }
    Mica::Core::ByteSearch.index(("a" * 60_000).to_slice, needle) { |steps| first ||= steps; total += steps }
    first.should eq(Mica::Core::ByteSearch::STEP_CHUNK)
    total.should be >= needle.size
  end

  it "14: points a normalization error at the offending character" do
    error = expect_raises(Mica::XML::NormalizationError) do
      Mica::XML.parse("<?xml version='1.1'?><a>xé</a>", CHECKED_11)
    end
    error.byte_offset.should eq(26)
    error.position.column.should eq(27)
  end
end
