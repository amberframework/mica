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
  "[0-9A-Za-z_]{40}",
  "x[a-z]{64}",
  "[^\\n]{40}",
  "\\w{2}",
  "[a-z]{1,64}",
  "\\w{2,40}?x",
  "[0-9A-Za-z_]{0,100}",
  "\\p{L}{3,40}",
  "(?:[-a-z.]{1,256})\\.[a-z]{1,6}",
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
    program_of("[a-z]{31}").list_of_runs.should be_empty
    program_of("(?:ab){500}").list_of_runs.should be_empty
    program_of("[a-z]{32}").list_of_runs.size.should eq(1)
  end

  it_satisfies "REGEX-R2-compiler", "holds a counted ASCII class as a run of its one byte state" do
    program = program_of("[0-9A-Za-z_]{256}")
    run = program.list_of_runs.first
    run.list_of_block_states.size.should eq(1)
    program.list_of_transitions.should be_empty
    written = program_of("[0-9A-Za-z_]" * 256)
    program.state_count.should eq(written.state_count)
    haystack = "b" * 300
    found = Mica::Regex::Expression.new("[0-9A-Za-z_]{256}", compile_limits: TRUSTED).match(haystack, limits: LIMITS)
    found.try(&.byte_end(0)).should eq(256)
  end

  it_satisfies "REGEX-R2-compiler", "holds the optional copies of a counted class as an optional run, not unrolled" do
    program = program_of("\\A[-a-zA-Z0-9@:%._\\+~#=]{1,256}\\z")
    optional = program.list_of_runs.find(&.optional).should_not be_nil
    optional.copies.should eq(255)
    optional.stride.should eq(2)
    # The split of each copy is worked out, not written: the program's own
    # list holds a handful of states for 513.
    program.runs_pending?.should be_true
    program.state_count.should be > 510
    limits = Mica::Regex::SearchLimits::TRUSTED_INPUT
    pattern = Mica::Regex::Expression.new("\\A[-a-zA-Z0-9@:%._\\+~#=]{1,256}\\z", compile_limits: TRUSTED)
    pattern.match("a" * 256, limits: limits).should_not be_nil
    pattern.match("a" * 257, limits: limits).should be_nil
    pattern.match("", limits: limits).should be_nil
  end

  it_satisfies "REGEX-R2-compiler", "matches through an optional run as through the copies one by one, greedy and lazy" do
    # The reference wraps the class in a group, which no run holds, so its
    # copies are compiled one by one; the whole matches must agree.
    {
      {"[a-z]{1,64}", "([a-z]){1,64}"}, {"[a-z]{2,64}?q", "([a-z]){2,64}?q"}, {"\\w{0,40}x", "(\\w){0,40}x"},
      {"\\p{L}{3,40}", "(\\p{L}){3,40}"}, {"x[0-9]{0,33}y", "x([0-9]){0,33}y"},
      {"[-a-z.]{1,256}\\.[a-z]{1,6}", "([-a-z.]){1,256}\\.([a-z]){1,6}"},
    }.each do |source, unrolled|
      expression = Mica::Regex::Expression.new(source, compile_limits: TRUSTED)
      expression.program.list_of_runs.any?(&.optional).should be_true
      reference = Mica::Regex::Expression.new(unrolled, compile_limits: TRUSTED)
      reference.program.list_of_runs.any?(&.optional).should be_false
      {"", "q", "abcq", "a" * 70 + "q", "x" + "7" * 33 + "y", "x" + "7" * 34 + "y", "δ" * 50,
       "mail.example.com", "a" * 300 + ".org", "x" * 39 + "x"}.each do |haystack|
        found = expression.match(haystack, limits: LIMITS)
        expected = reference.match(haystack, limits: LIMITS)
        {found.try(&.byte_begin(0)), found.try(&.byte_end(0))}.should eq({expected.try(&.byte_begin(0)), expected.try(&.byte_end(0))})
      end
    end
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
