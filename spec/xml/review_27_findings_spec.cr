require "../spec_helper"

# Regression specs for the twenty-seventh Codex code review of 2026-10-24.
describe "Codex review 27 findings" do
  it "1: charges validating a long XML version value" do
    meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
    value = "1.#{"0" * 100_000}"
    Mica::XML.parse("<?xml version='#{value}'?><r/>", meter: meter)
    meter.operations.should be >= 3 * value.bytesize
  end

  it "12: checks expanded attribute names in a builder without rehashing a long URI" do
    uri = "urn:#{"u" * 1_000_000}"
    attributes = (1..2_000).to_h { |number| {"p:a#{number}", "1"} }
    attributes["xmlns:p"] = uri
    uri_ids = 0
    prefix_ids = 0
    Mica::XML.build do |xml|
      xml.element("r", attributes) do
        # The URI is interned once for its binding; each attribute looks up
        # its prefix's small id instead of hashing the URI again.
        uri_ids = xml.@uri_ids.size
        prefix_ids = xml.@uri_ids_by_prefix["p"].size
      end
    end
    uri_ids.should eq(1)
    prefix_ids.should eq(1)
    expect_raises(Mica::XML::BuilderError, /duplicates/) do
      Mica::XML.build { |xml| xml.element("r", {"xmlns:p" => "urn:x", "xmlns:q" => "urn:x", "p:a" => "1", "q:a" => "2"}) { } }
    end
  end

  it "13: settles the name-table work of an expansion with inherited bindings" do
    reader = Mica::XML::Reader.new("<r xmlns:p='urn:p'><p:x p:a='1'/><f/></r>")
    reader.read
    reader.read
    before = reader.operations
    reader.expand.document.xpath_nodes("//p:x", namespaces: {"p" => "urn:p"}).size.should eq(1)
    (reader.operations - before).should be >= "xmlns:p".bytesize
    after_expand = reader.operations
    reader.read.should be_true
    (reader.operations - after_expand).should be < 200
  end
end
