require "../spec_helper"

# The class blocks generated into `ClassMemo::Prebuilt`
# (scripts/generate_class_blocks.cr) must be the blocks the builder makes
# for their sets, or a pattern would compile differently in a process that
# found its class there.
private def static_set(set_id : Int32, negated : Bool) : Mica::Regex::CodePointSet
  bounds = Mica::Regex::Unicode.decoded_ranges(set_id).to_a
  return Mica::Regex::CodePointSet.from_bounds(bounds) unless negated
  complement = [] of Int32
  first = 0
  bounds.each_slice(2) do |(low, high)|
    complement << first << low - 1 if low > first
    first = high + 1
  end
  complement << first << Mica::Regex::CodePointSet::MAX_CODE_POINT if first <= Mica::Regex::CodePointSet::MAX_CODE_POINT
  Mica::Regex::CodePointSet.from_bounds(complement)
end

describe Mica::Regex::ClassMemo do
  describe ".block_for" do
    it "decodes each prebuilt block to the block its set builds" do
      Mica::Regex::ClassMemo::Prebuilt::LIST_OF_ENTRIES.size.should be > 0
      Mica::Regex::ClassMemo::Prebuilt::LIST_OF_ENTRIES.each do |entry|
        set = static_set(entry[0], entry[1])
        prebuilt = Mica::Regex::ClassMemo.prebuilt_block_of?(set) || raise "no prebuilt block for set #{entry[0]}"
        prebuilt.should eq(Mica::Regex::ClassMemo.build_from_trie(set))
      end
    end

    it "finds no prebuilt block for a set that is not prebuilt" do
      set = Mica::Regex::CodePointSet.from_bounds([0x41, 0x5A, 0x400, 0x4FF])
      Mica::Regex::ClassMemo.prebuilt_block_of?(set).should be_nil
      word = static_set(Mica::Regex::Unicode::Tables::SET_XWD, false).list_of_bounds.dup
      word[-1] -= 1
      Mica::Regex::ClassMemo.prebuilt_block_of?(Mica::Regex::CodePointSet.from_bounds(word)).should be_nil
    end

    it "compiles prebuilt classes to the same matches" do
      limits = Mica::Regex::SearchLimits::TRUSTED_INPUT
      regex = Mica::Regex::Expression.new("\\w+ \\W \\d+\\D\\pL\\PL", compile_limits: Mica::Regex::CompileLimits::TRUSTED_PATTERN)
      match = regex.search("Привет_1 , 42xЖ!", limits: limits) || raise "no match"
      match[0].should eq("Привет_1 , 42xЖ!")
      regex.search("Привет_1 , 42xЖЖ", limits: limits).should be_nil
    end
  end
end
