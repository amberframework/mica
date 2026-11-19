require "../spec_helper"

# Findings of the sixth R3 review: under `CompileOptions::FirstLine` the
# Pike VM and the bounded backtracker stop once no live thread or allowed
# start remains, instead of stepping uncharged to the end of the haystack;
# a call validates its haystack in windows the meter allows, so a 100 us
# deadline stops a long validation; and the arrays a program and a lazy
# DFA build lazily are published with release/acquire ordering.
private TRUSTED    = Mica::Regex::CompileLimits::TRUSTED_PATTERN
private REQUEST    = Mica::Regex::SearchLimits::REQUEST
private FIRST_LINE = Mica::Regex::CompileOptions::FirstLine
private UNLIMITED  = Mica::Regex::SearchLimits.custom(work_ceiling: Int64::MAX // 2, work_per_byte: 1_000_000_i64)

private def first_line_program(source : String) : Mica::Regex::Program
  Mica::Regex::Expression.new(source, FIRST_LINE, compile_limits: TRUSTED).program
end

# The shortest of five timings of the block, in seconds.
private def fastest_of_five(& : -> _) : Float64
  (1..5).min_of do
    started = Time.instant
    yield
    (Time.instant - started).total_seconds
  end
end

# The shortest time *engine* takes to search "\n" + "a" * *tail* from 0,
# unanchored, on a fresh meter each run.
private def first_line_search_seconds(source : String, tail : Int32, engine : Mica::Regex::Engine) : Float64
  program = first_line_program(source)
  bytes = ("\n" + "a" * tail).to_slice
  slots = Slice(Int64).new(program.slot_count, Mica::Regex::PikeVM::UNSET)
  first_line_end = 0 # the line feed at 0
  fastest_of_five do
    meter = Mica::Regex::SearchMeter.new(UNLIMITED, program.state_count, bytes.size, nil)
    found = if engine.pike_vm?
              pike = Mica::Regex::PikeVM.new(program, false, Mica::Regex::CachePool.new)
              pike.prepare
              pike.search(bytes, 0, bytes.size, 0, false, false, false, meter, slots, first_line_end, false)
            else
              backtracker = Mica::Regex::BoundedBacktracker.new(program, program.slot_count)
              backtracker.visit_limit = 1_000_000_i64
              backtracker.search(bytes, 0, bytes.size, 0, false, false, meter, slots, first_line_end)
            end
    found.should be_false
  end
end

describe "Mica::Regex R3 sixth review findings" do
  it_satisfies "REGEX-R2-limits", "stops a FirstLine search once no thread is live and no start is allowed, whatever follows the first line" do
    {Mica::Regex::Engine::PikeVM, Mica::Regex::Engine::Backtracker}.each do |engine|
      {"\\d", "(\\d)", "a\\d", "(?:a|b)*\\d"}.each do |source|
        short = first_line_search_seconds(source, 4096, engine)
        long = first_line_search_seconds(source, 16 << 20, engine)
        # Before the fix the long search stepped through 16 MiB after the
        # line feed, thousands of times the short one.
        {source, engine, long < short * 8 + 50e-6}.should eq({source, engine, true})
      end
    end
  end

  it_satisfies "REGEX-R2-limits", "raises DeadlineExceededError promptly on a FirstLine search of a long haystack under a 100 us deadline" do
    haystack = "\n" + "a" * (16 << 20)
    {"\\d", "(\\d)", "a\\d", "(?:a|b)*\\d"}.each do |source|
      expression = Mica::Regex::Expression.new(source, FIRST_LINE, compile_limits: TRUSTED)
      started = Time.instant
      expect_raises(Mica::DeadlineExceededError) do
        expression.match(haystack, limits: REQUEST, timeout: 100.microseconds)
      end
      # Validating 16 MiB alone takes about 1 ms on an M1 in a release
      # build; the deadline stops the call well before that.
      (Time.instant - started).should be < 20.milliseconds
    end
    # Validation of text that is not ASCII is metered the same way.
    cyrillic = "ж" * (8 << 20)
    started = Time.instant
    expect_raises(Mica::DeadlineExceededError) do
      Mica::Regex::Expression.new("q", compile_limits: TRUSTED).match(cyrillic, limits: REQUEST, timeout: 100.microseconds)
    end
    (Time.instant - started).should be < 20.milliseconds
  end

  it_satisfies "REGEX-R2-limits", "answers a FirstLine search of an already validated haystack without reading past the first line" do
    haystack = "\n" + "a" * (16 << 20)
    expression = Mica::Regex::Expression.new("\\d", FIRST_LINE, compile_limits: TRUSTED)
    # The first call validates the haystack and the lease remembers it.
    expression.match(haystack, limits: REQUEST).should be_nil
    seconds = fastest_of_five { expression.match(haystack, limits: REQUEST, timeout: 100.microseconds).should be_nil }
    seconds.should be < 100e-6
  end

  it_satisfies "REGEX-R2-limits", "validates in windows that never split a character and names the first invalid byte" do
    haystack = "ж" * 300_000 + "\xff" + "a"
    expression = Mica::Regex::Expression.new("q", compile_limits: TRUSTED)
    error = expect_raises(Mica::EncodingError) { expression.match(haystack, limits: REQUEST) }
    error.message.to_s.should contain("not valid UTF-8")
    error.position.byte_offset.should eq(600_000)
    # Every window boundary falls between characters: a window that ends
    # inside "ж" would report a valid haystack invalid.
    {7, 64, 4097}.each do |repeat|
      valid = "ж€😀a" * repeat
      expression.match(valid, limits: REQUEST).should be_nil
    end
  end
end

