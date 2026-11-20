require "../spec_helper"

# Round 9 case work: a prefilter without the literals another literal of
# its set begins, a search at starts that hands a haystack full of failed
# candidates to the unanchored DFA, a first-byte scan that reads by words
# once its candidates prove dense, start states kept as entries, and the
# search from the end of the text for a program whose every match ends
# there. Each path must give the Pike VM's answer.
private TRUSTED   = Mica::Regex::CompileLimits::TRUSTED_PATTERN
private UNLIMITED = Mica::Regex::SearchLimits.custom(work_ceiling: Int64::MAX // 2, work_per_byte: 1_000_000_i64)

private def program_of(source : String) : Mica::Regex::Program
  Mica::Regex::Expression.new(source, Mica::Regex::CompileOptions::None, compile_limits: TRUSTED).program
end

# The slots *engine* finds in *haystack* from *byte_index*, or nil.
private def slots_from(program : Mica::Regex::Program, haystack : String, byte_index : Int32,
                       engine : Mica::Regex::Engine) : Array(Int64)?
  searcher = Mica::Regex::Searcher.new(program, haystack, UNLIMITED, nil, engine)
  slots = searcher.find(byte_index, Mica::Regex::MatchOptions::None, true)
  slots.try(&.to_a)
ensure
  searcher.try(&.finish)
end

# Every successive match (as `String#scan` steps) on the default path and
# on the Pike VM, each from a searcher of its own per call.
private def same_as_pike_vm(source : String, haystack : String) : Nil
  program = program_of(source)
  byte_index = 0
  while byte_index <= haystack.bytesize
    expected = slots_from(program, haystack, byte_index, Mica::Regex::Engine::PikeVM)
    {source, byte_index, slots_from(program, haystack, byte_index, Mica::Regex::Engine::Auto)}
      .should eq({source, byte_index, expected})
    break unless expected
    finish = expected[1].to_i32
    byte_index = finish > expected[0] ? finish : finish + 1
    while byte_index < haystack.bytesize && haystack.byte_at(byte_index) & 0xC0 == 0x80
      byte_index += 1
    end
  end
end

# A haystack of *count* short quoted words, with *tail* after them.
private def quoted_words(count : Int32, tail : String) : String
  String.build do |io|
    count.times { |index| io << (index.even? ? "'w" : "\"é") << index << "', " }
    io << tail
  end
end

describe "Mica::Regex round 9 case work" do
  describe "Prefilter.without_covered_literals" do
    it "drops each literal another literal of the set begins" do
      list = ["'ASIA", "'AKIA", "\"ASIA", "'", "\""].map(&.to_slice)
      kept = Mica::Regex::Prefilter.without_covered_literals(list).map { |literal| String.new(literal) }
      kept.should eq(["'", "\""])
    end

    it "returns the list itself when no literal is covered" do
      list = ["as", "break", "const"].map(&.to_slice)
      Mica::Regex::Prefilter.without_covered_literals(list).should be(list)
    end

    it "finds the matches the Pike VM finds with the covered literals gone" do
      same_as_pike_vm(%q{(('|")((?:ASIA|AKIA)([A-Z0-7]{4}))('|"))|('|")[a-z]{3}('|")}, quoted_words(40, "'AKIA0123' 'abc'"))
    end
  end

  describe "a search at starts over dense failed candidates" do
    it "finds a match past many failed tries, as the Pike VM does" do
      source = %q{['"][A-Z]{3}[0-9]['"]}
      same_as_pike_vm(source, quoted_words(300, "'ABC7'"))
      same_as_pike_vm(source, quoted_words(300, "no match here"))
      same_as_pike_vm(source, "'ABC1' " + quoted_words(200, "\"XYZ2\" and 'QRS3'"))
    end

    it "resumes at a character boundary after a multibyte candidate" do
      same_as_pike_vm(%q{[é'][a-z]{4}[0-9]}, ("é1 " * 200) + "éabcd5")
    end
  end

  describe "a first-byte scan over dense candidates" do
    it "reads by words and stops at the first candidate of each" do
      source = %q{["'][^"']{0,8}[?!.]["']}
      haystack = ("'ab', \"cd\", " * 100) + "'yes!' and \"no.\""
      same_as_pike_vm(source, haystack)
      same_as_pike_vm(source, haystack + "x" * 13)
    end
  end

  describe "SearchPlan.ends_at_text_end?" do
    it "holds when every match passes \\z or a $ before its end" do
      {"[ -~]*XYZ$", "abc\\z", "(?:x|y)$", "a*$", "(?:ab$|cd\\z)", "$\\n"}.each do |source|
        {source, Mica::Regex::SearchPlan.ends_at_text_end?(program_of(source))}.should eq({source, true})
      end
    end

    it "does not hold when a match can end before the end" do
      {"abc", "a$|b", "(?m)x$", "x(?:$)?", "[ -~]*XYZ.*"}.each do |source|
        {source, Mica::Regex::SearchPlan.ends_at_text_end?(program_of(source))}.should eq({source, false})
      end
    end
  end

  describe "a search from the end of the text" do
    it "finds the leftmost match the Pike VM finds" do
      {"[ -~]*XYZ$", "[ -~]*XYZ\\z", "[XYZ]ABC$", "a*$", "(?:b|ab)c?$", "(a)(b)?\\n?$", "$", "\\z", "é+$"}.each do |source|
        {"", "\n", "XYZ", "abcXYZ", "line\nabcXYZ", "abcXYZ\n", "abcXYZ\n\n", "zABC\n", "aab\n", "ab", "abc",
         "abc\nab", "ééé", "aé\néé\n", "xXYZ\nyXYZ"}.each do |haystack|
          same_as_pike_vm(source, haystack)
        end
      end
    end

    it "keeps the required-byte check for an anchored program (^...$)" do
      program = program_of("^[a-z]+@[a-z]+$")
      haystack = "a" * 100_000 + "!"
      searcher = Mica::Regex::Searcher.new(program, haystack, UNLIMITED, nil, Mica::Regex::Engine::Auto)
      searcher.find(0, Mica::Regex::MatchOptions::None, false).should be_nil
      # No engine ran: the haystack lacks the `@` every match reads.
      searcher.last_path.should eq(Mica::Regex::Searcher::Path::None)
      searcher.finish
      {"ab@cd", "ab@cd\n", "ab@cd!", "@cd", "ab@"}.each { |text| same_as_pike_vm("^[a-z]+@[a-z]+$", text) }
    end

    it "reads the end of a long haystack only" do
      program = program_of("[ -~]*ABCDEFGHIJKLMNOPQRSTUVWXYZ$")
      haystack = ("abcdefghij\n" * 100_000) + "tail ABCDEFGHIJKLMNOPQRSTUVWXYZ"
      searcher = Mica::Regex::Searcher.new(program, haystack, UNLIMITED, nil, Mica::Regex::Engine::Auto)
      slots = searcher.find(0, Mica::Regex::MatchOptions::None, false)
      slots.try(&.to_a.first(2)).should eq([haystack.bytesize - 31, haystack.bytesize])
      # Validation reads each byte once; the DFAs read the last line and
      # the bytes before it (the forward search would read all of them).
      searcher.meter.operations.should be < haystack.bytesize.to_i64 + 1_000
      searcher.finish
    end
  end
end
