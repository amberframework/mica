require "../spec_helper"

# Findings of the fourth R3 review: a lease reserves a lazy-DFA cache's
# bytes before it makes the builder the cache uses, a character index is
# turned into a byte index under the call's deadline and meter, and the
# lazy DFA's and one-pass DFA's stepping loops have each chunk allowed by
# the meter before they read it.
private TRUSTED = Mica::Regex::CompileLimits::TRUSTED_PATTERN
private REQUEST = Mica::Regex::SearchLimits::REQUEST
private NONE    = Mica::Regex::MatchOptions::None

# The operations a search had charged when it raised *error*.
private def operations_of(error : Mica::Regex::SearchLimitError) : Int64
  error.message.to_s[/A search of (\d+) operations/, 1].to_i64
end

# Limits whose allowance is exactly *ceiling* operations.
private def ceiling_limits(ceiling : Int64) : Mica::Regex::SearchLimits
  Mica::Regex::SearchLimits.custom(work_ceiling: ceiling, work_per_byte: 1_000_i64)
end

# The operations one search of *program* over *haystack* on *engine*
# charges when nothing stops it.
private def full_cost(program : Mica::Regex::Program, haystack : String, engine : Mica::Regex::Engine,
                      captures : Bool) : Int64
  limits = ceiling_limits(Int64::MAX // 2)
  searcher = Mica::Regex::Searcher.new(program, haystack, limits, nil, engine, Mica::Regex::CachePool.new)
  searcher.find(0, NONE, captures)
  operations = searcher.meter.operations
  searcher.finish
  operations
end

# Checks that a search of *program* over *haystack* on *engine*, run
# under allowances spread over the part of its cost after validation (or
# over its *last* operations only, to aim at the engine that runs last),
# stops each time one operation past the allowance: no loop reads a byte
# before the meter allows it.
private def expect_stops_at_the_allowance(source : String, haystack : String, engine : Mica::Regex::Engine,
                                          captures : Bool, last : Int64? = nil) : Nil
  program = Mica::Regex::Expression.new(source, compile_limits: TRUSTED).program
  total = full_cost(program, haystack, engine, captures)
  first = last ? total - last : haystack.bytesize.to_i64 + 1
  (total - first).should be > 3 * Mica::Regex::PrefilterScan::CHARGE_CHUNK
  8.times do |step|
    ceiling = first + (total - first - 1) * step // 8
    searcher = Mica::Regex::Searcher.new(program, haystack, ceiling_limits(ceiling), nil, engine,
      Mica::Regex::CachePool.new)
    error = expect_raises(Mica::Regex::SearchLimitError) { searcher.find(0, NONE, captures) }
    error.limit_name.should eq("max_work")
    {source, engine, ceiling, operations_of(error)}.should eq({source, engine, ceiling, ceiling + 1})
  end
end

describe "Mica::Regex R3 fourth review findings" do
  it_satisfies "REGEX-R3-cache-pool", "makes no DFA builder for a cache the pool refuses" do
    program = Mica::Regex::Expression.new("\\w+", compile_limits: TRUSTED).program
    pool = Mica::Regex::CachePool.new(max_bytes: 1_i64, max_cache_bytes: 1_i64)
    lease = program.plan.lease(pool)
    forward = program.plan.forward.should_not be_nil
    lease.forward_cache(forward).should be_nil
    lease.@builder.should be_nil
    reverse = program.plan.reverse.should_not be_nil
    lease.reverse_cache(reverse).should be_nil
    lease.@builder.should be_nil
    pool.reserved_bytes.should eq(0)
    program.plan.give_back(lease)
  end

  it_satisfies "REGEX-R3-cache-pool", "keeps the builder a cache holds, and drops one no cache holds" do
    program = Mica::Regex::Expression.new("\\w+", compile_limits: TRUSTED).program
    forward = program.plan.forward.should_not be_nil
    reverse = program.plan.reverse.should_not be_nil
    # Room for the forward cache's first reservation step and no more.
    pool = Mica::Regex::CachePool.new(max_bytes: Mica::Regex::CachePool::RESERVATION_BYTES)
    lease = program.plan.lease(pool)
    lease.forward_cache(forward).should_not be_nil
    builder = lease.@builder.should_not be_nil
    lease.reverse_cache(reverse).should be_nil
    lease.@builder.should be(builder)
    program.plan.give_back(lease)
  end

  it_satisfies "REGEX-R2-limits", "reads the deadline before it turns a character index into a byte index" do
    {"a", "\\Ab", "[ab]+", "(a)(b)?"}.each do |source|
      expression = Mica::Regex::Expression.new(source, compile_limits: TRUSTED)
      # Past the end, inside the haystack, and on an invalid haystack: the
      # deadline is read before any byte.
      {"a", "ab", String.new(Bytes[0x61, 0xff, 0x62])}.each do |haystack|
        {1, 2, 5}.each do |pos|
          expect_raises(Mica::DeadlineExceededError) do
            expression.match(haystack, pos, limits: REQUEST, timeout: -1.second)
          end
          expect_raises(Mica::DeadlineExceededError) do
            expression.matches?(haystack, pos, limits: REQUEST, timeout: -1.second)
          end
        end
      end
    end
  end

  it_satisfies "REGEX-R2-limits", "charges the character index conversion to the call's meter, window by window" do
    haystack = "д" * 100_000
    pos = 99_999
    # Validation (one operation per byte) fits; the conversion reads up to
    # the last character's first byte, so it stops one operation past the
    # allowance, before the byte it could not pay for. Each call has its
    # own expression, so each validates the haystack.
    ceiling = haystack.bytesize.to_i64 + 50_000
    first = Mica::Regex::Expression.new("a", compile_limits: TRUSTED)
    second = Mica::Regex::Expression.new("a", compile_limits: TRUSTED)
    {-> { first.match(haystack, pos, limits: ceiling_limits(ceiling)) },
     -> { second.matches?(haystack, pos, limits: ceiling_limits(ceiling)) }}.each do |call|
      error = expect_raises(Mica::Regex::SearchLimitError) { call.call }
      error.limit_name.should eq("max_work")
      operations_of(error).should eq(ceiling + 1)
    end
  end

  it_satisfies "REGEX-R2-limits", "finds the same match from a character index as String#char_index_to_byte_index" do
    random = Random.new(20261119)
    alphabet = ['a', 'b', 'é', 'д', '中', '😀', ' ']
    sources = {"a", "b+", "\\w+", "(a|é)(д)?", "\\b\\w", "$", ""}
    expressions = sources.map { |source| Mica::Regex::Expression.new(source, compile_limits: TRUSTED) }
    300.times do
      haystack = String.build { |io| random.rand(0..12).times { io << alphabet.sample(random) } }
      (-1..haystack.size + 2).each do |pos|
        expressions.each do |expression|
          byte_index = haystack.char_index_to_byte_index(pos)
          expected = byte_index ? expression.match_at_byte_index(haystack, byte_index, limits: REQUEST) : nil
          found = expression.match(haystack, pos, limits: REQUEST)
          {expression.source, haystack, pos, found.try(&.byte_begin(0)), found.try(&.byte_end(0))}.should eq(
            {expression.source, haystack, pos, expected.try(&.byte_begin(0)), expected.try(&.byte_end(0))})
          expression.matches?(haystack, pos, limits: REQUEST).should eq(!expected.nil?)
        end
      end
    end
  end

  it_satisfies "REGEX-R2-limits", "splits by the empty pattern as String#split does, charging each character first" do
    empty = Mica::Regex::Expression.new("", compile_limits: TRUSTED)
    {"", "a", "aé中😀b", "дд д"}.each do |haystack|
      {nil, 1, 2, 3, 10}.each do |limit|
        {false, true}.each do |remove_empty|
          expected = haystack.split(//, limit, remove_empty: remove_empty)
          empty.split(haystack, limit, remove_empty: remove_empty, limits: REQUEST).should eq(expected)
        end
      end
    end
    haystack = "д" * 10_000
    ceiling = haystack.bytesize.to_i64 + 5_000
    error = expect_raises(Mica::Regex::SearchLimitError) { empty.split(haystack, limits: ceiling_limits(ceiling)) }
    operations_of(error).should eq(ceiling + 1)
  end

  it_satisfies "REGEX-R3-dfa", "has the forward lazy DFA's chunks allowed before it reads them" do
    expect_stops_at_the_allowance("[a-z]+[0-9]", "abcdefghij" * 2_000, Mica::Regex::Engine::NoAccelerators, false)
  end

  it_satisfies "REGEX-R3-dfa", "has the forward lazy DFA's ASCII runs allowed before it reads them" do
    expect_stops_at_the_allowance("(?s)\\A.*é", "abcdefghij" * 2_000, Mica::Regex::Engine::NoAccelerators, false)
  end

  it_satisfies "REGEX-R3-dfa", "has the reverse lazy DFA's chunks allowed before it reads them" do
    # The reverse search from the match end reads the haystack last.
    haystack = "abcdefghij" * 2_000 + "0"
    expect_stops_at_the_allowance("[a-z]+0", haystack, Mica::Regex::Engine::NoAccelerators, false,
      last: haystack.bytesize.to_i64 - 100)
  end

  it_satisfies "REGEX-R3-short-match", "has each start's DFA steps allowed before it reads them" do
    expect_stops_at_the_allowance("[a-q][^u-z]{13}x", "abcdefghijklmnopqrstuvwxyz" * 800,
      Mica::Regex::Engine::EachStart, false)
  end

  it_satisfies "REGEX-R3-one-pass", "has the anchored one-pass search's steps allowed before it reads them" do
    expect_stops_at_the_allowance("\\A([a-z]+)[0-9]", "abcdefghij" * 2_000, Mica::Regex::Engine::NoAccelerators, true)
  end

  it_satisfies "REGEX-R3-one-pass", "has the one-pass capture pass's steps allowed before it reads them" do
    # The capture pass over the span reads it last.
    haystack = "abcdefghij" * 2_000 + "0"
    expect_stops_at_the_allowance("([a-z]+)0", haystack, Mica::Regex::Engine::NoAccelerators, true,
      last: haystack.bytesize.to_i64 - 100)
  end

  it_satisfies "REGEX-R3-one-pass", "has the capture pass's ASCII runs allowed before it reads them" do
    haystack = "abcdefghij" * 2_000
    expect_stops_at_the_allowance("(?s)\\A((.*)()($))", haystack, Mica::Regex::Engine::NoAccelerators, true,
      last: haystack.bytesize.to_i64 - 100)
  end
end
