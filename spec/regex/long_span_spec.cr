require "../spec_helper"
require "../../fuzz/regex_engine_differential"

# Long spans on the one-pass DFA and the lazy DFA: an anchored search with
# groups that runs on the one-pass DFA to its end (it no longer stops after
# `Searcher::MAX_TRY_BYTES` when the DFA is decisive), builds that DFA on
# its first search when the haystack is long, and the self-looping states
# (`.*`, `[^\n]*`) that both DFAs step through in a run. Every result is
# checked against the Pike VM with every slot.
private TRUSTED = Mica::Regex::CompileLimits::TRUSTED_PATTERN
private LIMITS  = Mica::Regex::SearchLimits::TRUSTED_INPUT

private def slots_of(program : Mica::Regex::Program, haystack : String, engine : Mica::Regex::Engine,
                     captures : Bool = true) : Array(Int64)?
  searcher = Mica::Regex::Searcher.new(program, haystack, LIMITS, nil, engine)
  found = searcher.find(0, Mica::Regex::MatchOptions::None, captures).try(&.to_a)
  searcher.finish
  found
end

private def matches_of?(program : Mica::Regex::Program, haystack : String, engine : Mica::Regex::Engine) : Bool
  searcher = Mica::Regex::Searcher.new(program, haystack, LIMITS, nil, engine)
  found = searcher.matches?(0, Mica::Regex::MatchOptions::None)
  searcher.finish
  found
end

# Checks every Auto path against the Pike VM on *haystack*, twice (the
# first search may build the one-pass DFA, the second runs on it), and
# returns the Pike VM's slots.
private def agree(source : String, haystack : String) : Array(Int64)?
  program = Mica::Regex::Expression.new(source, compile_limits: TRUSTED).program
  program.end_first_searches
  expected = slots_of(program, haystack, Mica::Regex::Engine::PikeVM)
  2.times do
    slots_of(program, haystack, Mica::Regex::Engine::Auto).should eq(expected), "#{source.inspect} on #{haystack.size} bytes"
    span = slots_of(program, haystack, Mica::Regex::Engine::Auto, false)
    span.should eq(expected.try(&.first(2))), "span of #{source.inspect}"
    matches_of?(program, haystack, Mica::Regex::Engine::Auto).should eq(!expected.nil?)
  end
  expected
end

describe "Mica::Regex long spans" do
  it_satisfies "REGEX-R3-one-pass", "reads a long anchored match with groups in one pass, with the Pike VM's groups" do
    text = "fn main() {\n    let é = 1;\n}\n" * 400
    agree("(?s)^((.*)()()($))", text).should eq([0_i64, text.bytesize.to_i64] * 3 + [text.bytesize.to_i64] * 6)
    agree("(?s)^((.*)()()($))", text.rchop).try(&.[1]).should eq(text.bytesize - 1)
    agree("^([^\\n]*)\\n", text).should eq([0_i64, 12_i64, 0_i64, 11_i64])
    agree("\\A([a-z ]*)(\\{)", "fn main " * 300 + "{").try(&.[3]).should eq(2400)
    agree("^(a*)(b*)$", "a" * 5000 + "b" * 3000).try(&.[5]).should eq(8000)
    agree("^(a*)(b*)$", "a" * 5000 + "b" * 3000 + "\n").try(&.[5]).should eq(8000)
    agree("^(a*)(b*)$", "a" * 5000 + "b" * 3000 + "a").should be_nil
    agree("^(a*)(b*)\\z", "a" * 5000 + "b" * 3000 + "\n").should be_nil
    agree("^(?:(a)|b)*$", "ab" * 3000).try(&.[3]).should eq(5999)
    agree("^([ab]*?)(b)", "a" * 4000 + "b").try(&.[3]).should eq(4000)
    agree("(?m)^(.*)$", "é" * 2000 + "\nrest").try(&.[3]).should eq(4000)
  end

  it_satisfies "REGEX-R3-one-pass", "agrees with the Pike VM on generated anchored patterns over long haystacks" do
    seed = 20261119_u64
    alphabet = ["a", "b", "é", "\n"]
    1_000.times do |index|
      random = Random::PCG32.new(seed, index.to_u64)
      source = (random.rand(2) == 0 ? "^" : "\\A") + "(" + EngineDifferential.pattern(random) + ")" +
               ["", "$", "\\z", "\\Z"].sample(random)
      program = begin
        Mica::Regex::Expression.new(source, compile_limits: TRUSTED).program
      rescue Mica::Regex::SyntaxError | Mica::Regex::CompileLimitError
        next
      end
      4.times do |shape|
        unit = String.build { |io| (1 + random.rand(6)).times { io << alphabet.sample(random) } }
        haystack = unit * (64 * program.state_count // unit.bytesize + 2 + shape * 37)
        haystack += "\n" if shape == 3
        agree(source, haystack)
      end
    end
  end
end
