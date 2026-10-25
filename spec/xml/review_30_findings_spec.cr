require "../spec_helper"

# Regression specs for the thirtieth Codex code review of 2026-10-24.
# Each threshold sits between the count measured before the fix and the
# count after it, so a lost charge fails the example.
describe "Codex review 30 findings" do
  it "1: leaves the tree and its attribute index unchanged when a rename trips the budget" do
    declarations = (1..2_000).join(' ') { |number| "xmlns:p#{number}='urn:#{number}' p#{number}:a='0'" }
    document = Mica::XML.parse("<r z='1' #{declarations}/>")
    root = document.root || fail "no root"
    renamed = false
    failures = 0
    base = 0
    until renamed || base > 100_000
      document.renew_edit_meter(Mica::Core::WorkBudget.new(operations_per_unit: 0, base_operations: base))
      attribute = root.attributes["z"]? || fail "no z"
      begin
        attribute.name = "a"
        renamed = true
      rescue Mica::WorkBudgetExceededError
        failures += 1
        attribute.name.should eq("z")
        root.attributes["z"]?.should eq(attribute)
        root["z"]?.should eq("1")
      end
      base += 25
    end
    failures.should be > 0
    renamed.should be_true
    (root.attributes["a"]? || fail "no a").content.should eq("1")
    root["z"]?.should be_nil
  end

  it "2: stops an evaluation on an expired meter before reading the root's declarations" do
    document = Mica::XML.parse("<r xmlns:p='urn:#{"u" * 100_000}'/>")
    meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.new(timeout: 1.nanosecond))
    sleep 1.millisecond
    expression = Mica::XML::XPath.compile("1")
    expect_raises(Mica::DeadlineExceededError) { expression.evaluate(document.root || fail("no root"), meter: meter) }
    meter.operations.should be < 1_000
  end

  it "4: points duplicate-attribute and end-tag errors at the offending name" do
    error = expect_raises(Mica::ParseError, /does not match/) { Mica::XML.parse("<a></b>") }
    error.byte_offset.should eq(5)
    error = expect_raises(Mica::ParseError, /appears twice/) { Mica::XML.parse("<r a='1' a='2'/>") }
    error.byte_offset.should eq(9)
  end

  it "6: charges building order keys for an edited document" do
    document = Mica::XML.parse("<r>#{"<e/>" * 5_000}</r>")
    (document.root || fail "no root")["x"] = "1"
    meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
    document.xpath_nodes("//e | //e", meter: meter).size.should eq(5_000)
    meter.operations.should be >= 505_000
  end

  it "7: charges the reverse pass of the preceding axis" do
    document = Mica::XML.parse("<r>#{"<e/>" * 5_000}<last/></r>")
    meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
    document.xpath_nodes("//last/preceding::e", meter: meter).size.should eq(5_000)
    meter.operations.should be >= 253_000
  end
end
