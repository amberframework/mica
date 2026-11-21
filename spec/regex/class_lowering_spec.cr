require "../spec_helper"

# `ClassLowering` against sets worked out here member by member: the fold
# partners of ASCII members (read from the per-letter fold sets) and the
# union of a class's members (whose last stream is copied in one pass).
private TRUSTED = Mica::Regex::CompileLimits::TRUSTED_PATTERN

private def lowered(pattern : String, options = Mica::Regex::CompileOptions::None,
                    limits = TRUSTED) : Mica::Regex::CodePointSet
  root = Mica::Regex::Syntax.parse(pattern, dialect: :crystal, compile_limits: limits, options: options).root
  char_class = root.as?(Mica::Regex::Ast::CharClass) || raise "#{pattern} is not a class"
  ledger = Mica::Regex::AllocationLedger.new(limits.max_compile_bytes)
  Mica::Regex::ClassLowering.lower(char_class, :crystal, limits, ledger, Mica::Core::WorkMeter.new)
end

private def static_ranges(set_id : Int32) : Array({Int32, Int32})
  ranges = [] of {Int32, Int32}
  Mica::Regex::Unicode.each_range(set_id) { |first, last| ranges << {first, last} }
  ranges
end

# The members of *first*..*last* with their fold partners, read from the
# fold table one code point at a time.
private def folded(first : Int32, last : Int32, restricted : Bool) : Mica::Regex::CodePointSet
  ranges = [{first, last}]
  (first..last).each do |code_point|
    Mica::Regex::Unicode.each_fold_partner(code_point) do |partner|
      next if restricted && (partner < 0x80) != (code_point < 0x80)
      ranges << {partner, partner}
    end
  end
  Mica::Regex::CodePointSet.new(ranges)
end

private def hex(code_point : Int32) : String
  "\\x{#{code_point.to_s(16)}}"
end

describe Mica::Regex::ClassLowering do
  describe ".lower" do
    it "folds each ASCII member to the partners the fold table gives it" do
      ignore_case = Mica::Regex::CompileOptions::IgnoreCase
      restricted = ignore_case | Mica::Regex::CompileOptions::CaselessRestrict
      (0x00..0x7F).each do |code_point|
        # Two items, so the class is lowered as a written class.
        pattern = "[#{hex(code_point)}#{hex(code_point)}]"
        lowered(pattern, ignore_case).should eq(folded(code_point, code_point, false))
        lowered(pattern, restricted).should eq(folded(code_point, code_point, true))
      end
    end

    it "folds ranges that lie in ASCII, straddle its end, or lie past it" do
      ignore_case = Mica::Regex::CompileOptions::IgnoreCase
      restricted = ignore_case | Mica::Regex::CompileOptions::CaselessRestrict
      [{0x00, 0x7F}, {0x41, 0x5A}, {0x61, 0x7A}, {0x4B, 0x53}, {0x40, 0x17F}, {0x6B, 0x212A}, {0x7F, 0x80},
       {0x80, 0x24F}, {0x212A, 0x212B}].each do |first, last|
        pattern = "[#{hex(first)}-#{hex(last)}]"
        lowered(pattern, ignore_case).should eq(folded(first, last, false))
        lowered(pattern, restricted).should eq(folded(first, last, true))
      end
      lowered("[A-Za-z0-9.+-]", ignore_case).to_s.should eq("[\\x{2B}\\x{2D}\\x{2E}0-9A-Za-z\\x{17F}\\x{212A}]")
      lowered("[A-Za-z0-9.+-]", restricted).to_s.should eq("[\\x{2B}\\x{2D}\\x{2E}0-9A-Za-z]")
    end

    it "unites a large set with the other members of its class" do
      punctuation = static_ranges(Mica::Regex::Unicode::Tables::SET_GCG_P)
      letters = static_ranges(Mica::Regex::Unicode::Tables::SET_GCG_L)
      written = [0x24, 0x2B, 0x3C, 0x3D, 0x3E, 0x5E, 0x60, 0x7C, 0x7E].map { |code_point| {code_point, code_point} }
      lowered("[$+<=>^`|~\\p{P}]").should eq(Mica::Regex::CodePointSet.new(punctuation + written))
      lowered("[\\p{P}\\x{10FFFF}]").should eq(Mica::Regex::CodePointSet.new(punctuation + [{0x10FFFF, 0x10FFFF}]))
      lowered("[!\\p{P}\\x{10FFFF}]").should eq(Mica::Regex::CodePointSet.new(punctuation + [{0x10FFFF, 0x10FFFF}]))
      lowered("[\\p{L}\\p{P}]").should eq(Mica::Regex::CodePointSet.new(letters + punctuation))
      lowered("[\\x{20}-\\x{2FFF}\\p{L}]").should eq(Mica::Regex::CodePointSet.new(letters + [{0x20, 0x2FFF}]))
      lowered("[\\x{3000}-\\x{10FFFF}\\p{P}]").should eq(Mica::Regex::CodePointSet.new(punctuation + [{0x3000, 0x10FFFF}]))
      # A complement is read gap by gap.
      complement = lowered("[^\\p{L}]")
      lowered("[\\P{L}a]").should eq(Mica::Regex::CodePointSet.new(complement.list_of_bounds.each_slice(2).map { |(first, last)| {first, last} }.to_a + [{0x61, 0x61}]))
    end

    it "holds a united class to max_class_ranges" do
      count = lowered("[$+<=>^`|~\\p{P}]").range_count
      lowered("[$+<=>^`|\\x{7E}\\p{P}]", limits: Mica::Regex::CompileLimits.custom(max_class_ranges: count)).range_count.should eq(count)
      [count - 1, count - 2, 20, 1].each do |max_class_ranges|
        error = expect_raises(Mica::Regex::CompileLimitError) do
          lowered("[$+<=>^`|\\x{7E}\\p{P}]", limits: Mica::Regex::CompileLimits.custom(max_class_ranges: max_class_ranges))
        end
        error.limit_name.should eq("max_class_ranges")
      end
    end

    it "holds a united class to max_compile_bytes" do
      # A class no example before this one lowered, so its set is not one the process kept.
      error = expect_raises(Mica::Regex::CompileLimitError) do
        lowered("[q$+<=>^`|~\\p{P}]", limits: Mica::Regex::CompileLimits.custom(max_class_ranges: 10_000, max_compile_bytes: 8_192))
      end
      error.limit_name.should eq("max_compile_bytes")
    end
  end
end
