require "../spec_helper"

# The bounded backtracker follows a greedy loop of one byte state (`.*`,
# `[a-z]*`) in a tight loop and pushes the loop's exits as one job of
# starts (see "Engines" in docs/regex.md). Its matches and groups must be
# the Pike VM's.
private TRUSTED = Mica::Regex::CompileLimits::TRUSTED_PATTERN
private LIMITS  = Mica::Regex::SearchLimits::TRUSTED_INPUT

# Every match of *source* in *haystack* on one searcher of *engine*, with
# its groups; after an empty match the next search starts one character on.
private def scan(source : String, haystack : String, engine : Mica::Regex::Engine) : Array(Array(Int64))
  program = Mica::Regex::Expression.new(source, compile_limits: TRUSTED).program
  searcher = Mica::Regex::Searcher.new(program, haystack, LIMITS, nil, engine)
  list_of_spans = [] of Array(Int64)
  offset = 0
  while found = searcher.find(offset, Mica::Regex::MatchOptions::None, true)
    list_of_spans << found.to_a
    finish = found[1].to_i32
    break if finish >= haystack.bytesize && found[1] == found[0]
    offset = found[1] > found[0] ? finish : finish + Char::Reader.new(haystack, pos: finish).current_char_width
  end
  searcher.finish
  list_of_spans
end

private LOOP_PATTERNS = {
  ".*[^A-Z]|[A-Z]",
  "(.*)x",
  "[a-z]*\\d",
  "(?:[a-z]*|b)c",
  "(a*)(a*)b",
  ".*",
  "(?s).*y$",
  "\\w*é",
  "x(.*)(.*)z",
  "(?:a*)*b",
  "[^\\n]*\\n",
}

private LOOP_HAYSTACKS = {
  "",
  "AAAAAAAAAA",
  "AAAAaAAAA",
  "abc def x yz xx",
  "aaaa aab aaac",
  "line one\nline two\nx",
  "héllo wörld é y",
  "x" + "a" * 40 + "z" + "b" * 10 + "z",
  "\n\n",
}

describe Mica::Regex::BoundedBacktracker do
  describe "#search" do
    it "follows greedy byte loops to the Pike VM's matches and groups" do
      LOOP_PATTERNS.each do |source|
        LOOP_HAYSTACKS.each do |haystack|
          expected = scan(source, haystack, Mica::Regex::Engine::PikeVM)
          scan(source, haystack, Mica::Regex::Engine::Backtracker).should eq(expected), "#{source} on #{haystack.inspect}"
        end
      end
    end

    it "gives a first search over a long loop the same answer as the plan" do
      haystack = "A" * 200
      first = Mica::Regex::Expression.new(".*[^A-Z]|[A-Z]", compile_limits: TRUSTED)
      first.search(haystack, limits: LIMITS).try(&.byte_end(0)).should eq(1)
      first.search(haystack + "a", limits: LIMITS).try(&.byte_end(0)).should eq(201)
    end
  end
end
