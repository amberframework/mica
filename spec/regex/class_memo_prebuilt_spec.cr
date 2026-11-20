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

# *set* with its ASCII members replaced by *ascii*.
private def with_ascii_members(set : Mica::Regex::CodePointSet, ascii : Array(Int32)) : Mica::Regex::CodePointSet
  bounds = [] of Int32
  ascii.sort.each do |member|
    if !bounds.empty? && bounds[-1] == member - 1
      bounds[-1] = member
    else
      bounds << member << member
    end
  end
  set.list_of_bounds.each_slice(2) do |(low, high)|
    next if high < 0x80
    low = Math.max(low, 0x80)
    if !bounds.empty? && bounds[-1] == low - 1
      bounds[-1] = high
    else
      bounds << low << high
    end
  end
  Mica::Regex::CodePointSet.from_bounds(bounds)
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

    it "derives the block of a set that differs from a prebuilt set only in ASCII members" do
      word = static_set(Mica::Regex::Unicode::Tables::SET_XWD, false)
      non_word = static_set(Mica::Regex::Unicode::Tables::SET_XWD, true)
      letters = static_set(Mica::Regex::ClassMemo::Prebuilt::LIST_OF_ENTRIES[4][0], false)
      ascii_word = (0x30..0x39).to_a + (0x41..0x5A).to_a + [0x5F] + (0x61..0x7A).to_a
      list_of_variants = [
        with_ascii_members(word, ascii_word + [0x2B, 0x2D, 0x2E]),          # (?i)[\w+\-.]
        with_ascii_members(word, ascii_word - [0x5F]),                      # [^\W_]
        with_ascii_members(word, [0x41]),                                   # one ASCII member
        with_ascii_members(word, [] of Int32),                              # none
        with_ascii_members(non_word, [0x21, 0x7F]),                         # a range that starts in ASCII
        with_ascii_members(letters, (0x30..0x39).to_a + (0x61..0x7A).to_a), # [\pL\d] without upper case
      ]
      list_of_variants.each do |set|
        derived = Mica::Regex::ClassMemo.prebuilt_block_of?(set) || raise "no derived block for #{set.list_of_bounds.first(6)}"
        derived.should eq(Mica::Regex::ClassMemo.build_from_trie(set))
      end
    end

    it "compiles a class derived from a prebuilt block to the same matches" do
      limits = Mica::Regex::SearchLimits::TRUSTED_INPUT
      regex = Mica::Regex::Expression.new("\\A[\\w+\\-.]+@[a-z\\d\\-]+(\\.[a-z\\d\\-]+)*\\.[a-z]+\\z",
        compile_limits: Mica::Regex::CompileLimits::TRUSTED_PATTERN, options: Mica::Regex::CompileOptions::IgnoreCase)
      regex.search("Jörg.Müller+tag@example.com", limits: limits).should_not be_nil
      regex.search("José_ſ\u{212A}@mail.example.org", limits: limits).should_not be_nil
      regex.search("jo sé@example.com", limits: limits).should be_nil
      regex.search("josé!@example.com", limits: limits).should be_nil
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
