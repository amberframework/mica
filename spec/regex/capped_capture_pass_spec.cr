require "../spec_helper"

private LIMITS = Mica::Regex::SearchLimits::TRUSTED_INPUT

private def program_of(source : String) : Mica::Regex::Program
  Mica::Regex::Expression.new(source, compile_limits: Mica::Regex::CompileLimits::TRUSTED_PATTERN).program
end

# Every match of *program* in *haystack*, with its groups, on one searcher
# of *engine*.
private def scan_groups(program : Mica::Regex::Program, haystack : String, engine : Mica::Regex::Engine) : Array(Array(Int64))
  searcher = Mica::Regex::Searcher.new(program, haystack, LIMITS, nil, engine)
  list_of_slots = [] of Array(Int64)
  offset = 0
  while found = searcher.find(offset, Mica::Regex::MatchOptions::None, true)
    list_of_slots << found.to_a
    offset = found[1] > found[0] ? found[1].to_i32 : found[1].to_i32 + 1
  end
  searcher.finish
  list_of_slots
end

private RUSSIAN = "Съешь же ещё этих мягких французских булок, да выпей чаю. Достопримечательность " \
                  "и человеконенавистничество — длинные слова; café naïve 12345 ünïcödé"

private OVERLAPPING_WORDS = "(\\p{L}{14})|(\\p{L}{13})|(\\p{L}{12})|(\\p{L}{11})|(\\p{L}{10})|" \
                            "(\\p{L}{9})|(\\p{L}{8})|(\\p{L}{7})|(\\p{L}{6})|(\\p{L}{5})"

describe "Mica::Regex capped capture pass" do
  it "reads the groups of a program too large for the bitset as the Pike VM does" do
    program = program_of(OVERLAPPING_WORDS)
    Mica::Regex::BoundedBacktracker.fits?(program, 28).should be_false
    Mica::Regex::BoundedBacktracker.fits_capped?(program, 28).should be_true
    expected = scan_groups(program, RUSSIAN, Mica::Regex::Engine::PikeVM)
    expected.size.should be > 5
    scan_groups(program, RUSSIAN, Mica::Regex::Engine::Auto).should eq(expected)
    scan_groups(program, RUSSIAN, Mica::Regex::Engine::NoAccelerators).should eq(expected)
  end

  it "falls back to the Pike VM, with the same groups, when the capped backtracker gives up" do
    # Each copy of `(\p{L}?)` may or may not read a letter, so the
    # backtracker visits far more than its cap of pairs before it finds
    # the split the Pike VM's priority order gives.
    program = program_of("(\\p{L}?){150}(\\p{L}{150})(\\p{L}*)")
    haystack = "abcdefghij" * 20 + " " + "Достопримечательность" * 8
    Mica::Regex::BoundedBacktracker.fits_capped?(program, 200).should be_true
    expected = scan_groups(program, haystack, Mica::Regex::Engine::PikeVM)
    expected.should_not be_empty
    scan_groups(program, haystack, Mica::Regex::Engine::Auto).should eq(expected)
  end
end
