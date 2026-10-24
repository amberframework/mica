require "../spec_helper"
require "../../fuzz/xml_fuzz"

# Seeded hostile-byte fuzzing of the reader and DOM (see fuzz/xml_fuzz.cr).
# Replay one case with XMLFuzz::MUTATOR.case_bytes(seed, iteration).
# Override the run with MICA_FUZZ_SEED / MICA_FUZZ_ITERATIONS; release
# campaigns use fuzz/campaign.cr.
private FUZZ_SEED       = (ENV["MICA_FUZZ_SEED"]? || "20261024").to_i64
private FUZZ_ITERATIONS = (ENV["MICA_FUZZ_ITERATIONS"]? || "20000").to_i

describe "Mica::XML fuzzing" do
  it_satisfies "MICA-HOSTILE-FUZZ", "survives #{FUZZ_ITERATIONS} seeded hostile mutations (seed #{FUZZ_SEED}) with no crash, overrun or String/IO disagreement" do
    campaign = Mica::Testing::FuzzCampaign.new(XMLFuzz::MUTATOR, FUZZ_SEED, XMLFuzz::OVERRUN_SLACK, check_determinism: true)
    default_budget_trips = 0
    report = campaign.run(FUZZ_ITERATIONS) do |bytes, iteration|
      trial = XMLFuzz.trial(bytes, iteration)
      error = trial.error
      tripped = error.is_a?(Mica::WorkBudgetExceededError) || error.is_a?(Mica::DeadlineExceededError)
      default_budget_trips += 1 if tripped && iteration % 4 != 3
      trial
    end
    report.list_of_crashes.first(5).should eq([] of String)
    report.list_of_budget_overruns.first(5).should eq([] of String)
    report.list_of_nondeterministic_cases.first(5).should eq([] of String)
    default_budget_trips.should eq(0)
    report.accepted.should be > 0
    report.budget_trips.should be > 0
  end
end
