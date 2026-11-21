require "../spec_helper"

# A static search validates its haystack in windows the meter allows (see
# `ValidateInWindows`), as the runtime engine does, so a deadline stops a
# long validation. Before, `StaticMatcher#open` validated in one pass after
# one up-front charge: under a 1 ms deadline a static search of 256 MiB of
# "é" ran 54.80 ms (median) before it raised, the runtime engine 1.04 ms.
private NEVER     = Mica::Regex.static("zzz[0-9]q")
private HOST_PORT = Mica::Regex.static(".*:(\\d+)")
private WORDS     = Mica::Regex.static("[a-zé]+")

# A budget no search here reaches, so only the deadline stops them.
private ROOMY    = Mica::Regex::SearchLimits.custom(work_ceiling: Int64::MAX // 4, work_per_byte: 4096_i64)
private DEADLINE = 1.millisecond
# The bound both engines must raise within: the one the runtime engine's
# validation deadline spec sets (review_r3_round6_findings_spec.cr).
private BOUND = 20.milliseconds

# The time from the call until it raised `Mica::DeadlineExceededError`.
private def time_to_deadline(& : -> _) : Time::Span
  started = Time.instant
  expect_raises(Mica::DeadlineExceededError) { yield }
  Time.instant - started
end

private def runtime(source : String) : Mica::Regex::Expression
  Mica::Regex.compile(source, dialect: :crystal, compile_limits: Mica::Regex::CompileLimits::TRUSTED_PATTERN)
end

describe "Mica::Regex.static validation under a deadline" do
  it_satisfies "REGEX-R2-limits", "stops a static search of 256 MiB of non-ASCII text within the runtime engine's bound" do
    wide = "é" * (128 << 20)
    wide.bytesize.should eq(256 << 20)
    runtime_spent = time_to_deadline do
      runtime("zzz[0-9]q").matches_at_byte_index?(wide, 0, limits: ROOMY, timeout: DEADLINE)
    end
    static_spent = {
      time_to_deadline { NEVER.matches?(wide, limits: ROOMY, deadline: DEADLINE) },
      time_to_deadline { NEVER.search_span(wide, limits: ROOMY, deadline: DEADLINE) },
      time_to_deadline { HOST_PORT.search_groups(wide, limits: ROOMY, deadline: DEADLINE) { |groups| groups.byte_end(1) } },
      time_to_deadline { WORDS.each_span(wide, limits: ROOMY, deadline: DEADLINE) { } },
    }
    runtime_spent.should be < BOUND
    static_spent.each { |spent| spent.should be < BOUND }
  end

  it_satisfies "REGEX-R2-limits", "stops a static search of 256 MiB of ASCII text within the same bound" do
    ascii = "a" * (256 << 20)
    time_to_deadline { NEVER.matches?(ascii, limits: ROOMY, deadline: DEADLINE) }.should be < BOUND
  end

  it_satisfies "REGEX-R2-limits", "validates in windows that never split a character and names the first invalid byte" do
    haystack = "ж" * 300_000 + "\xff" + "a"
    error = expect_raises(Mica::EncodingError) { NEVER.search_span(haystack) }
    error.message.to_s.should contain("not valid UTF-8")
    error.position.byte_offset.should eq(600_000)
    {7, 64, 4097, 40_000}.each do |repeat|
      NEVER.search_span("ж€😀a" * repeat).should be_nil
    end
  end

  it_satisfies "REGEX-R2-limits", "charges validation to the work budget so max_work stops it" do
    budget = Mica::Regex::SearchLimits.custom(work_ceiling: 4_096_i64, work_per_byte: 0_i64, work_per_state: 0_i64,
      base_work: 4_096_i64)
    error = expect_raises(Mica::Regex::SearchLimitError) { NEVER.matches?("é" * 1_000_000, limits: budget) }
    error.limit_name.should eq("max_work")
  end
end
