require "../spec_helper"

# The generated Unicode tables (src/mica/regex/unicode/tables.cr) are
# read-only static data read in place: these specs check that the readers
# see them whole and that the derived tables agree with the sets they come
# from.
describe Mica::Regex::Unicode do
  it "resolves every loose property name in the table, and nothing between them" do
    text = Mica::Regex::Unicode::Tables::PROPERTY_NAME_TEXT
    entries = Mica::Regex::Unicode::Tables::PROPERTY_NAMES
    previous = ""
    Mica::Regex::Unicode::Tables::PROPERTY_NAME_COUNT.times do |index|
      name = text.byte_slice(entries[index * 5], entries[index * 5 + 1])
      (name.to_slice <=> previous.to_slice).should be > 0
      property = Mica::Regex::Unicode.lookup(name)
      property.should_not be_nil
      if property
        property.kind.value.should eq(entries[index * 5 + 2])
        property.set_id.should eq(entries[index * 5 + 3])
      end
      previous = name
    end
    Mica::Regex::Unicode.lookup("").should be_nil
    Mica::Regex::Unicode.lookup("notaproperty").should be_nil
  end

  it "keeps the script-only set apart from the script extensions" do
    greek = Mica::Regex::Unicode.lookup("greek")
    script_only = Mica::Regex::Unicode.lookup("sc:greek")
    greek.try(&.kind).should eq(Mica::Regex::Unicode::PropertyKind::ScriptExtensions)
    script_only.try(&.kind).should eq(Mica::Regex::Unicode::PropertyKind::Script)
    greek.try(&.set_id).should_not eq(script_only.try(&.set_id))
  end

  it "reads each set's ranges in place, sorted, with a gap between them" do
    Mica::Regex::Unicode::Tables::SET_COUNT.times do |set_id|
      bounds = Mica::Regex::Unicode.decoded_ranges(set_id)
      bounds.read_only?.should be_true
      bounds.size.should eq(Mica::Regex::Unicode.range_count(set_id) * 2)
      (bounds.size // 2).times do |index|
        (bounds[index * 2] <= bounds[index * 2 + 1]).should be_true
        # A gap, so `ClassLowering` copies a set's ranges as they are.
        (bounds[index * 2 - 1] + 1 < bounds[index * 2]).should be_true if index > 0
      end
    end
  end

  it "has the word bitmap agree with the word set below U+10000" do
    0x10000.times do |code_point|
      expected = Mica::Regex::Unicode.includes?(Mica::Regex::Unicode::Tables::SET_XWD, code_point)
      Mica::Regex::Look.word_code_point?(code_point, false).should eq(expected)
    end
  end

  it "walks each simple case folding orbit back to its start" do
    orbits = Mica::Regex::Unicode::Tables::FOLD_ORBITS
    (orbits.size // 2).times do |index|
      code_point = orbits[index * 2]
      members = [] of Int32
      Mica::Regex::Unicode.each_fold_partner(code_point) { |partner| members << partner }
      members.empty?.should be_false
      members.includes?(code_point).should be_false
      (members.size < Mica::Regex::Unicode::Tables::LARGEST_ORBIT).should be_true
    end
  end
end
