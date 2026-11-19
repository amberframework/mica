require "../spec_helper"
require "../../fuzz/regex_fuzz"

# Seeded fuzzing of the Mica::Regex front end (see fuzz/regex_fuzz.cr):
# mutated seed patterns and grammar-generated patterns. Override the run
# with MICA_FUZZ_SEED / MICA_REGEX_FUZZ_ITERATIONS; release campaigns of a
# million patterns use fuzz/regex_campaign.cr.
private FUZZ_SEED       = (ENV["MICA_FUZZ_SEED"]? || "20261118").to_i64
private FUZZ_ITERATIONS = (ENV["MICA_REGEX_FUZZ_ITERATIONS"]? || "20000").to_i

describe "Mica::Regex fuzzing" do
  it_satisfies "REGEX-R1-fuzz", "survives #{FUZZ_ITERATIONS} seeded patterns (seed #{FUZZ_SEED}) with no crash, overrun or nondeterminism" do
    campaign = Mica::Testing::FuzzCampaign.new(RegexFuzz::MUTATOR, FUZZ_SEED, RegexFuzz::OVERRUN_SLACK, check_determinism: true)
    report = campaign.run(FUZZ_ITERATIONS) { |bytes, iteration| RegexFuzz.trial(bytes, FUZZ_SEED, iteration) }
    report.list_of_crashes.first(5).should eq([] of String)
    report.list_of_budget_overruns.first(5).should eq([] of String)
    report.list_of_nondeterministic_cases.first(5).should eq([] of String)
    report.accepted.should be > 0
    report.rejected.should be > 0
  end
end
