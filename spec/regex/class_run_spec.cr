require "../spec_helper"

# A counted large class (`\p{L}{256}`) compiles to a run of copies held as
# the class's block (`Program::ClassRun`), built into states only when the
# plan needs them (see "Engines" in docs/regex.md).
private TRUSTED = Mica::Regex::CompileLimits::TRUSTED_PATTERN
private LIMITS  = Mica::Regex::SearchLimits::TRUSTED_INPUT

private def program_of(source : String) : Mica::Regex::Program
  Mica::Regex::Expression.new(source, compile_limits: TRUSTED).program
end

# Every match of *program* in *haystack* on one searcher of *engine*, with
# its groups; after an empty match the next search starts one character on.
private def scan(program : Mica::Regex::Program, haystack : String, engine : Mica::Regex::Engine) : Array(Array(Int64))
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

private RUN_PATTERNS = {
  "\\p{L}{256}",
  "\\w{5}x",
  "(\\p{L}{14})|(\\p{L}{13})|(\\p{L}{5})",
  "a\\p{Greek}{100}b",
  "(?:\\pL{20}){2}",
  "\\pL{10,20}",
  "(\\pL{8})+",
  "(?:\\pL{8}|)*",
  "\\b\\w{12}\\b",
  "(?i)\\p{Ll}{20}",
  "\\p{L}{3}\\p{N}{400}",
}

describe Mica::Regex::Program::ClassRun do
  it_satisfies "REGEX-R2-compiler", "compiles a counted large class to a run that is not written as states" do
    program = program_of("\\p{L}{256}")
    program.list_of_runs.size.should eq(1)
    program.runs_pending?.should be_true
    program.list_of_runs.first.copies.should eq(256)
    pattern = Mica::Regex::Expression.new("\\p{L}{256}", compile_limits: TRUSTED)
    pattern.match("δ" * 256, limits: LIMITS).try(&.byte_end(0)).should eq(512)
    pattern.program.runs_pending?.should be_true
    program.list_of_states.size.should eq(program.state_count)
    program.runs_pending?.should be_false
  end

  it_satisfies "REGEX-R2-compiler", "builds the program its copies written out would compile to" do
    {
      {"\\p{L}{300}", "\\p{L}" * 300},
      {"x\\w{6}y", "x" + "\\w" * 6 + "y"},
      {"(?:\\p{Greek}{40})?", "(?:" + "\\p{Greek}" * 40 + ")?"},
      {"(\\p{L}{14})|(\\p{N}{5})", "(" + "\\p{L}" * 14 + ")|(" + "\\p{N}" * 5 + ")"},
    }.each do |counted, written|
      run_program = program_of(counted)
      run_program.list_of_runs.should_not be_empty
      written_program = program_of(written)
      written_program.list_of_runs.should be_empty
      run_program.state_count.should eq(written_program.state_count)
      # Read before the states are built, then after.
      run_program.state_count.times do |index|
        run_program.state_at(index).should eq(written_program.list_of_states[index])
      end
      run_program.to_s.should eq(written_program.to_s)
      run_program.list_of_class_blocks.should eq(written_program.list_of_class_blocks)
      run_program.list_of_shared_tables.size.should eq(written_program.list_of_shared_tables.size)
    end
  end

  it_satisfies "REGEX-R2-compiler", "leaves a few copies of a class as states" do
    program_of("\\w{2}").list_of_runs.should be_empty
    program_of("[a-z]{500}").list_of_runs.should be_empty
  end

  it_satisfies "REGEX-R2-compiler", "searches alike on every engine path" do
    haystack = "Ωmega δδδδδδδδδδδδδδδδ alpha extraordinarily 12345 " * 6 + "a" + "αβγδεζηθικλμνξοπρστυ" * 2 + "b" +
               "Ψ" * 300 + "٣" * 400
    RUN_PATTERNS.each do |source|
      reference = program_of(source)
      reference.list_of_runs.should_not be_empty
      expected = scan(reference, haystack, Mica::Regex::Engine::PikeVM)
      {
        Mica::Regex::Engine::Auto, Mica::Regex::Engine::NoAccelerators, Mica::Regex::Engine::EachStart,
        Mica::Regex::Engine::ReversedClasses, Mica::Regex::Engine::BacktrackedStarts, Mica::Regex::Engine::TwoPhase,
      }.each do |engine|
        scan(program_of(source), haystack, engine).should eq(expected)
      end
      found = Mica::Regex::Expression.new(source, compile_limits: TRUSTED).match(haystack, limits: LIMITS)
      if first = expected.first?
        found.try(&.byte_begin(0)).should eq(first[0])
        found.try(&.byte_end(0)).should eq(first[1])
      else
        found.should be_nil
      end
    end
  end
end
