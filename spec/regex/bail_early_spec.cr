require "../spec_helper"
require "./support/pcre2_search_corpus"
require "./support/conformance_approval"

# The bail-early suite: proof that Mica stops a search early, with its
# named limit error, when the caller's work budget or deadline runs out.
#
# PCRE2's own resource-limit tests (patterns that set (*LIMIT_MATCH=...),
# (*LIMIT_DEPTH=...) or (*LIMIT_HEAP=...)) test how PCRE2 refuses a runaway
# match, not what a pattern means, so they sit outside the PCRE2 replay
# (conformance/regex/pcre2/search_resource_limits.tsv). This suite covers
# that ground for Mica: the 7 PCRE2 limit patterns on their PCRE2
# haystacks, every family of the benchmark ReDoS set
# (bench/regex/corpus/redos.json on feature/regex-bench) at a 16 MiB
# haystack, and a `CompileOptions::FirstLine` search of a 16 MiB haystack.
#
# Every case runs twice, through every public search entry point:
#
# - under a deliberately small work budget, where it passes only when Mica
#   raises `SearchLimitError` naming `max_work` (or
#   `Mica::WorkBudgetExceededError`);
# - under a short deadline, where it passes only when Mica raises
#   `Mica::DeadlineExceededError`, and the error arrives within the bound
#   below.
#
# A returned result fails the case, and so does any other error.
#
# The deadline bound: the error arrives no later than the deadline, plus
# one `Core::WorkMeter::CLOCK_INTERVAL` of work (the meter reads the clock
# once per interval), plus `DEADLINE_SLACK`. One interval of work is
# measured on the same expression, haystack and entry point: the fastest
# of three calls whose budget is exactly `CLOCK_INTERVAL` operations.
module BailEarly
  # The fixed allowance past the deadline and one clock interval of work,
  # for clock reads, the error's construction, garbage collection and a
  # busy CI machine.
  DEADLINE_SLACK = 20.milliseconds

  # The deadline of the large cases.
  SHORT_DEADLINE = 100.microseconds

  # The deadline of the PCRE2 cases. Their haystacks are at most 60 bytes
  # and every search of them finishes in microseconds, before any nonzero
  # deadline can be relied on to pass; a zero deadline has passed when the
  # call starts, which proves each entry point reads the clock before it
  # searches.
  EXPIRED_DEADLINE = Time::Span.zero

  # The work budget of the large cases: one clock interval, a small part
  # of the work a 16 MiB haystack needs.
  SMALL_WORK = Mica::Core::WorkMeter::CLOCK_INTERVAL

  # The work budget of the PCRE2 cases, each of which needs more than 16
  # operations.
  TINY_WORK = 8_i64

  # The haystack size of the large cases.
  LARGE_HAYSTACK_BYTES = 16 << 20

  TRUSTED = Mica::Regex::CompileLimits::TRUSTED_PATTERN

  # The benchmark ReDoS set (bench/regex/corpus/redos.json): name, pattern,
  # and the haystack prepend + unit * n + append.
  LIST_OF_REDOS_FAMILIES = [
    {"nested-plus-dollar", "(a+)+$", "", "a", "b"},
    {"alternation-a-or-a", "(a|a)*b", "", "a", ""},
    {"alternation-a-or-aa-b", "(a|aa)*b", "", "a", ""},
    {"alternation-a-or-aa-c", "(a|aa)*c", "", "a", ""},
    {"double-plus-group", "(x+x+)+y", "", "x", ""},
    {"dot-star-a-twenty", "(.*a){20}", "", "a", ""},
    {"words-then-bang", "^(\\w+\\s?)*$", "", "ab ", "!"},
    {"owasp-email",
     "^([a-zA-Z0-9])(([\\-.]|[_]+)?([a-zA-Z0-9]+))*(@){1}[a-z0-9]+[.]{1}(([a-z]{2,3})|([a-z]{2,3}[.]{1}[a-z]{2,3}))$",
     "", "a", "!"},
    {"cloudflare-2019", ".*(?:.*=.*)", "x=", "x", ""},
    {"stack-overflow-2016", "^[\\s\\x{200c}]+|[\\s\\x{200c}]+$", "x", " ", "x"},
    {"alternation-overlap-abc", "(a|b|ab)*c", "", "ab", ""},
    {"optional-alternation", "(a|a?)+b", "", "a", ""},
    {"trailing-space-run", "\\s+$", "x", " ", "x"},
  ]

  alias EntryPoint = Proc(Mica::Regex::Expression, String, Mica::Regex::SearchLimits, Time::Span?, Nil)

  # Every public search entry point of `Expression`. `gsub` and `sub` are
  # the public faces of the private `replace`.
  LIST_OF_ENTRY_POINTS = [
    {"match", EntryPoint.new { |expression, haystack, limits, timeout|
      expression.match(haystack, limits: limits, timeout: timeout)
      nil
    }},
    {"match!", EntryPoint.new { |expression, haystack, limits, timeout|
      expression.match!(haystack, limits: limits, timeout: timeout)
      nil
    }},
    {"matches?", EntryPoint.new { |expression, haystack, limits, timeout|
      expression.matches?(haystack, limits: limits, timeout: timeout)
      nil
    }},
    {"match_at_byte_index", EntryPoint.new { |expression, haystack, limits, timeout|
      expression.match_at_byte_index(haystack, 0, limits: limits, timeout: timeout)
      nil
    }},
    {"matches_at_byte_index?", EntryPoint.new { |expression, haystack, limits, timeout|
      expression.matches_at_byte_index?(haystack, 0, limits: limits, timeout: timeout)
      nil
    }},
    {"search", EntryPoint.new { |expression, haystack, limits, timeout|
      expression.search(haystack, limits: limits, deadline: timeout)
      nil
    }},
    {"each_match", EntryPoint.new { |expression, haystack, limits, timeout|
      expression.each_match(haystack, limits: limits, timeout: timeout) { }
      nil
    }},
    {"scan", EntryPoint.new { |expression, haystack, limits, timeout|
      expression.scan(haystack, limits: limits, timeout: timeout)
      nil
    }},
    {"gsub", EntryPoint.new { |expression, haystack, limits, timeout|
      expression.gsub(haystack, "-", limits: limits, timeout: timeout)
      nil
    }},
    {"sub", EntryPoint.new { |expression, haystack, limits, timeout|
      expression.sub(haystack, "-", limits: limits, timeout: timeout)
      nil
    }},
    {"split", EntryPoint.new { |expression, haystack, limits, timeout|
      expression.split(haystack, limits: limits, timeout: timeout)
      nil
    }},
  ]

  # One case: a pattern, its compile options, its haystack, and the budget
  # and deadline it runs under.
  record Case, label : String, pattern : String, compile_options : Mica::Regex::CompileOptions,
    haystack : String, work_ceiling : Int64, deadline : Time::Span

  # The PCRE2 subjects whose pattern sets its own match-time limit.
  def self.list_of_pcre2_limit_ids : Array(String)
    ConformanceApproval.read_rows(PCRE2SearchCorpus::RESOURCE_LIMITS_PATH).keys
  end

  # The PCRE2 limit case *id*, with its PCRE2 pattern, options and haystack.
  def self.pcre2_case(id : String) : Case
    found = PCRE2SearchCorpus.scoped.find { |subject_id, _, _| subject_id == id }
    raise "no PCRE2 subject #{id}" unless found
    job = found[2].job
    raise "PCRE2 subject #{id} is out of scope: #{found[2].exclusion}" unless job
    Case.new(id, job.pattern, job.compile_options, job.haystack, TINY_WORK, EXPIRED_DEADLINE)
  end

  # The ReDoS family *family* at a haystack of at least 16 MiB.
  def self.redos_case(family : {String, String, String, String, String}) : Case
    name, pattern, prepend, unit, append = family
    haystack = prepend + unit * (LARGE_HAYSTACK_BYTES // unit.bytesize) + append
    Case.new(name, pattern, Mica::Regex::CompileOptions::None, haystack, SMALL_WORK, SHORT_DEADLINE)
  end

  # A FirstLine search whose first line is empty, over 16 MiB after it.
  def self.first_line_case : Case
    Case.new("FirstLine", "\\d", Mica::Regex::CompileOptions::FirstLine, "\n" + "a" * LARGE_HAYSTACK_BYTES,
      SMALL_WORK, SHORT_DEADLINE)
  end

  # Runs *test_case* under its small work budget through every entry
  # point and returns how each one that did not raise `max_work` behaved.
  def self.failures_under_budget(test_case : Case) : Array(String)
    expression = Mica::Regex::Expression.new(test_case.pattern, test_case.compile_options, compile_limits: TRUSTED)
    limits = Mica::Regex::SearchLimits.custom(work_ceiling: test_case.work_ceiling)
    LIST_OF_ENTRY_POINTS.compact_map do |entry_name, entry_point|
      error = error_from(entry_point, expression, test_case.haystack, limits, nil)
      next if error.is_a?(Mica::Regex::SearchLimitError) && error.limit_name == "max_work"
      next if error.is_a?(Mica::WorkBudgetExceededError)
      "#{entry_name}: #{describe(error)}"
    end
  end

  # Runs *test_case* under its deadline through every entry point and
  # returns how each one that did not raise `DeadlineExceededError` within
  # the bound behaved.
  def self.failures_under_deadline(test_case : Case) : Array(String)
    expression = Mica::Regex::Expression.new(test_case.pattern, test_case.compile_options, compile_limits: TRUSTED)
    unlimited = Mica::Regex::SearchLimits.custom(work_ceiling: Int64::MAX // 2, work_per_byte: 1_000_000_i64)
    LIST_OF_ENTRY_POINTS.compact_map do |entry_name, entry_point|
      started = Time.instant
      error = error_from(entry_point, expression, test_case.haystack, unlimited, test_case.deadline)
      elapsed = Time.instant - started
      next "#{entry_name}: #{describe(error)}" unless error.is_a?(Mica::DeadlineExceededError)
      bound = test_case.deadline + clock_interval_of_work(entry_point, expression, test_case.haystack) + DEADLINE_SLACK
      next if elapsed <= bound
      "#{entry_name}: DeadlineExceededError after #{elapsed.total_milliseconds.round(3)} ms, past the bound of #{bound.total_milliseconds.round(3)} ms"
    end
  end

  # The time *entry_point* takes on one `CLOCK_INTERVAL` of work: the
  # fastest of three calls under a budget of exactly that many operations.
  def self.clock_interval_of_work(entry_point : EntryPoint, expression : Mica::Regex::Expression,
                                  haystack : String) : Time::Span
    limits = Mica::Regex::SearchLimits.custom(work_ceiling: Mica::Core::WorkMeter::CLOCK_INTERVAL)
    (1..3).min_of do
      started = Time.instant
      error_from(entry_point, expression, haystack, limits, nil)
      Time.instant - started
    end
  end

  # Calls *entry_point* and returns the error it raised, or nil when it
  # returned.
  def self.error_from(entry_point : EntryPoint, expression : Mica::Regex::Expression, haystack : String,
                      limits : Mica::Regex::SearchLimits, timeout : Time::Span?) : Exception?
    entry_point.call(expression, haystack, limits, timeout)
    nil
  rescue error : Exception
    error
  end

  def self.describe(error : Exception?) : String
    return "returned a result" unless error
    "raised #{error.class}: #{error.message}"
  end
end

describe "Mica::Regex bail-early suite" do
  it_satisfies "REGEX-R2-limits", "lists the 7 PCRE2 resource-limit subjects, each a pattern that sets its own limit" do
    ids = BailEarly.list_of_pcre2_limit_ids
    ids.size.should eq(7)
    ids.each do |id|
      test_case = BailEarly.pcre2_case(id)
      {id, PCRE2SearchCorpus.sets_a_resource_limit?(test_case.pattern)}.should eq({id, true})
    end
  end

  describe "PCRE2 resource-limit patterns on their PCRE2 haystacks" do
    BailEarly.list_of_pcre2_limit_ids.each do |id|
      it_satisfies "REGEX-R2-limits", "#{id}: raises max_work under a #{BailEarly::TINY_WORK}-operation budget" do
        BailEarly.failures_under_budget(BailEarly.pcre2_case(id)).should eq([] of String)
      end

      it_satisfies "REGEX-R2-limits", "#{id}: raises DeadlineExceededError under an expired deadline" do
        BailEarly.failures_under_deadline(BailEarly.pcre2_case(id)).should eq([] of String)
      end
    end
  end

  describe "ReDoS families at 16 MiB" do
    BailEarly::LIST_OF_REDOS_FAMILIES.each do |family|
      it_satisfies "REGEX-R2-limits", "#{family[0]} #{family[1]}: raises max_work under a one-interval budget" do
        BailEarly.failures_under_budget(BailEarly.redos_case(family)).should eq([] of String)
      end

      it_satisfies "REGEX-R2-limits", "#{family[0]} #{family[1]}: raises DeadlineExceededError under a 100 us deadline" do
        BailEarly.failures_under_deadline(BailEarly.redos_case(family)).should eq([] of String)
      end
    end
  end

  describe "CompileOptions::FirstLine" do
    it_satisfies "REGEX-R2-limits", "\"\\n\" + \"a\" * 16 MiB: raises max_work under a one-interval budget" do
      BailEarly.failures_under_budget(BailEarly.first_line_case).should eq([] of String)
    end

    # Regression test for the FirstLine deadline fix (round 5 of the R3
    # tuning): a FirstLine search once stepped uncharged to the end of the
    # haystack, so a 100 us deadline went unread for milliseconds.
    it_satisfies "REGEX-R2-limits", "\"\\n\" + \"a\" * 16 MiB: raises DeadlineExceededError under a 100 us deadline" do
      BailEarly.failures_under_deadline(BailEarly.first_line_case).should eq([] of String)
    end
  end
end
