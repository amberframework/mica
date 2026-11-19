require "../spec_helper"

# Findings of the R3 review: work charged in windows by the literal
# accelerators, the deadline read again after a caller's block, and the
# cache-pool items covered in automata_spec.cr.
private TRUSTED = Mica::Regex::CompileLimits::TRUSTED_PATTERN

describe "Mica::Regex R3 review findings" do
  it_satisfies "REGEX-R3-selection", "stops a literal-accelerated search within one charge window of max_work" do
    haystack = "abcdefghij" * 100_000
    ceiling = 1_200_000_i64
    limits = Mica::Regex::SearchLimits.custom(work_ceiling: ceiling, work_per_byte: 1_000_i64)
    # The memchr literal search, the packed search and the rare-byte
    # prefilter, each over a haystack with no candidate.
    {"zzzq", "zq|yq|xq|wq", "q[a-z]+"}.each do |source|
      expression = Mica::Regex::Expression.new(source, compile_limits: TRUSTED)
      error = expect_raises(Mica::Regex::SearchLimitError) { expression.match(haystack, limits: limits) }
      error.limit_name.should eq("max_work")
      operations = error.message.to_s[/A search of (\d+) operations/, 1].to_i64
      operations.should be <= ceiling + 2 * Mica::Regex::PrefilterScan::CHARGE_CHUNK
    end
  end

  it_satisfies "REGEX-R3-selection", "counts the time of an iteration block against the call's timeout" do
    expression = Mica::Regex::Expression.new("\\d", compile_limits: TRUSTED)
    yielded = 0
    expect_raises(Mica::DeadlineExceededError) do
      expression.each_match("1 2 3 4 5", limits: Mica::Regex::SearchLimits::REQUEST, timeout: 5.milliseconds) do
        yielded += 1
        sleep 3.milliseconds
      end
    end
    yielded.should be < 5
  end
end
