require "../spec_helper"

# A search that checks first for the ASCII bytes every match contains (see
# "Required bytes" in docs/regex.md), and a first search that hands a
# pattern the backtracker struggles with to the plan.
private TRUSTED = Mica::Regex::CompileLimits::TRUSTED_PATTERN
private LIMITS  = Mica::Regex::SearchLimits::TRUSTED_INPUT

private def compiled_program(source : String) : Mica::Regex::Program
  Mica::Regex::Expression.new(source, compile_limits: TRUSTED).program
end

# The ASCII bytes every match of *program* contains, found by walking
# every state and transition (large classes included, which
# `StartFilter.required_bytes` steps over): a byte is required when the
# match state cannot be reached once the states that read only it are
# removed.
private def required_bytes_by_walking(program : Mica::Regex::Program) : Set(UInt8)
  required = Set(UInt8).new
  (0_u8..0x7F_u8).each do |byte|
    visited = Set(Int32).new
    list_of_pending = [program.start_state]
    reached = false
    while index = list_of_pending.pop?
      next unless visited.add?(index)
      state = program.state_at(index)
      case state.kind
      when .match?        then reached = true
      when .split?        then list_of_pending << state.next_state << state.alternate
      when .save?, .look? then list_of_pending << state.next_state
      when .byte_range?
        list_of_pending << state.next_state unless state.low == byte && state.high == byte
      when .sparse?
        state.alternate.times do |offset|
          transition = program.transition_at(index, state, offset)
          list_of_pending << transition.target unless transition.low == byte && transition.high == byte
        end
      end
    end
    required << byte unless reached
  end
  required
end

# The fewest bytes a match of *program* spans, found by relaxing every
# edge until nothing changes.
private def shortest_match_by_walking(program : Mica::Regex::Program) : Int32
  distance = Array(Int32).new(program.state_count, Int32::MAX)
  distance[program.start_state] = 0
  shortest = Int32::MAX
  changed = true
  while changed
    changed = false
    program.state_count.times do |index|
      here = distance[index]
      next if here == Int32::MAX
      state = program.state_at(index)
      list_of_steps = [] of {Int32, Int32}
      case state.kind
      when .match?        then shortest = Math.min(shortest, here)
      when .split?        then list_of_steps << {state.next_state, here} << {state.alternate, here}
      when .save?, .look? then list_of_steps << {state.next_state, here}
      when .byte_range?   then list_of_steps << {state.next_state, here + 1}
      when .sparse?
        state.alternate.times { |offset| list_of_steps << {program.transition_at(index, state, offset).target, here + 1} }
      end
      list_of_steps.each do |target, candidate|
        next unless candidate < distance[target]
        distance[target] = candidate
        changed = true
      end
    end
  end
  shortest
end

describe "Mica::Regex required bytes" do
  describe "StartFilter" do
    it_satisfies "REGEX-R3-required-bytes", "steps over a large class to the bytes and the length a walk of its states finds" do
      list_of_sources = {
        "\\A[\\w+\\-.]+@[a-z\\d\\-]+(\\.[a-z\\d\\-]+)*\\.[a-z]+\\z", "\\w+@\\w+\\.com", "\\w:", "\\pL{2}z", "[^']+'",
        "\\d+px", "(?:\\w|:):", "\\W;\\w", "x\\p{Lowercase}*y", "[\\x{80}-\\x{10FFFF}]+q", "\\w", "\\D?\\d", "a\\w{0,3}b|c\\wb",
      }
      {Mica::Regex::CompileOptions::None, Mica::Regex::CompileOptions::IgnoreCase}.each do |options|
        list_of_sources.each do |source|
          program = Mica::Regex::Expression.new(source, options, compile_limits: TRUSTED).program
          walked = required_bytes_by_walking(program)
          found = Mica::Regex::StartFilter.required_bytes(program)
          # The analysis keeps at most `MAX_REQUIRED_BYTES` of the rarest
          # `MAX_REQUIRED_CANDIDATES` single-byte states.
          found.each { |byte| walked.should contain(byte) }
          if walked.size <= Mica::Regex::StartFilter::MAX_REQUIRED_BYTES
            found.to_set.should eq(walked)
          else
            found.size.should eq(Mica::Regex::StartFilter::MAX_REQUIRED_BYTES)
          end
          Mica::Regex::StartFilter.shortest_match(program).should eq(shortest_match_by_walking(program))
        end
      end
    end
  end

  describe "Program#list_of_required_bytes" do
    it_satisfies "REGEX-R3-required-bytes", "holds the rarest ASCII bytes every match reads" do
      compiled_program("(a|aa)*c").list_of_required_bytes.to_a.should eq(['c'.ord.to_u8])
      compiled_program("\\w+\\s+Holmes").list_of_required_bytes.to_a.should eq(['H', 'm', 'l'].map(&.ord.to_u8))
      compiled_program("a(?:b|c:)d").list_of_required_bytes.to_a.should eq(['d', 'a'].map(&.ord.to_u8))
      compiled_program("x|y").list_of_required_bytes.should be_empty
      compiled_program("c?").list_of_required_bytes.should be_empty
    end
  end

  describe "StartFilter#rejects?" do
    it_satisfies "REGEX-R3-required-bytes", "rejects a short span exactly when it lacks a start or a required byte" do
      program = compiled_program("x[a-z]*@[a-z]*\\.[a-z]+")
      filter = program.plan.start_filter
      list_of_required = filter.list_of_required_bytes
      list_of_required.should_not be_empty
      random = Random.new(20261120)
      alphabet = "xab@.z".to_slice
      3000.times do
        size = random.rand(0..80)
        text = Bytes.new(size) { alphabet[random.rand(alphabet.size)] }
        from = random.rand(0..size)
        span = text[from, size - from]
        anchored = random.next_bool
        last = anchored ? from : size - filter.minimum_bytes
        no_start = from > size - filter.minimum_bytes || (from..last).none? { |at| at < size && text[at] == 0x78_u8 }
        missing = list_of_required.any? { |byte| !span.includes?(byte) }
        filter.rejects?(text, from, anchored).should eq(no_start || missing)
      end
    end
  end

  describe "Searcher#find" do
    it_satisfies "REGEX-R3-required-bytes", "runs no engine when a byte every match needs is missing" do
      haystack = "a" * 10_000
      searcher = Mica::Regex::Searcher.new(compiled_program("(a|aa)*c"), haystack, LIMITS, nil)
      searcher.find(0, Mica::Regex::MatchOptions::None, true).should be_nil
      searcher.last_path.should eq(Mica::Regex::Searcher::Path::None)
      # Validation and one scan for the c.
      searcher.meter.operations.should be <= 2 * haystack.bytesize
      searcher.finish
    end

    it_satisfies "REGEX-R3-required-bytes", "reads the haystack once per required byte over an iteration call" do
      program = compiled_program("\\w+:")
      haystack = "ab: " * 2_000
      with_check = Mica::Regex::Searcher.new(program, haystack, LIMITS, nil)
      without_check = Mica::Regex::Searcher.new(program, haystack, LIMITS, nil, Mica::Regex::Engine::NoAccelerators)
      counts = {with_check, without_check}.map do |searcher|
        offset = 0
        count = 0
        while found = searcher.find(offset, Mica::Regex::MatchOptions::None, false)
          count += 1
          offset = found[1].to_i32
        end
        searcher.finish
        count
      end
      counts.should eq({2_000, 2_000})
      # One read of the haystack, plus a few operations the two paths count
      # differently at its end.
      (with_check.meter.operations - without_check.meter.operations).should be <= haystack.bytesize + 64
    end

    it_satisfies "REGEX-R3-required-bytes", "agrees with the engines that do not check on every engine path" do
      list_of_cases = {
        {"(a|aa)*c", "aaaa"}, {"(a|aa)*c", "aaac"}, {"(?i)x\\d", "X1"}, {"a(?:b|c:)d", "ac:d abd"},
        {"\\bH\\w+", "say Hi"}, {"(?m)^:x$", "a\n:x\n"},
      }
      list_of_cases.each do |source, haystack|
        expected = Mica::Regex::Searcher.new(compiled_program(source), haystack, LIMITS, nil, Mica::Regex::Engine::PikeVM)
          .find(0, Mica::Regex::MatchOptions::None, true).try(&.to_a)
        found = Mica::Regex::Searcher.new(compiled_program(source), haystack, LIMITS, nil)
          .find(0, Mica::Regex::MatchOptions::None, true).try(&.to_a)
        found.should eq(expected)
      end
    end
  end

  describe "Program#required_bytes_for_first_search" do
    it_satisfies "REGEX-R3-first-search", "counts the transitions a large class reads from its shared table" do
      program = compiled_program("\\w{2}z")
      program.list_of_transitions.should be_empty
      program.list_of_shared_tables.should_not be_empty
      # About 700 states read about 2,800 transitions from shared tables:
      # within a 1,000-byte span's allowance (4,256), past a 200-byte one's
      # (1,056), though the states alone fit it.
      program.required_bytes_for_first_search(200).should be_nil
      program.required_bytes_for_first_search(1_000).try(&.to_a).should eq(['z'.ord.to_u8])
    end
  end

  describe "a first search" do
    it_satisfies "REGEX-R3-first-search", "checks the required bytes of a small program before the backtracker runs" do
      pattern = Mica::Regex::Expression.new("(a|a)*b", compile_limits: TRUSTED)
      pattern.match("a" * 200, limits: LIMITS).should be_nil
      pattern.program.plan_built?.should be_false
    end

    it_satisfies "REGEX-R3-first-search", "hands a search the backtracker has not decided within its visits to the plan" do
      haystack = "a" * 255 + "!"
      first = Mica::Regex::Expression.new("(a|a)*$", compile_limits: TRUSTED)
      searcher = Mica::Regex::Searcher.first_search(first.program, haystack, LIMITS, nil, Mica::Regex::CachePool.default)
      searcher.find(0, Mica::Regex::MatchOptions::None, true).try(&.to_a).should eq([256, 256, -1, -1])
      searcher.last_path.should_not eq(Mica::Regex::Searcher::Path::Backtracker)
      first.program.plan_built?.should be_true
      # Within the backtracker's visits and the plan's work, not the
      # backtracker's worst case (m·(n + 1) visits).
      worst = first.program.state_count.to_i64 * (haystack.bytesize + 1)
      searcher.meter.operations.should be < worst
      searcher.finish
    end
  end
end
