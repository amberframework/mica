require "../spec_helper"
require "../../fuzz/form_fuzz"

# Seeded hostile-byte fuzzing of Mica::Form (see fuzz/form_fuzz.cr).
# Replay one case with FormFuzz::MUTATOR.case_bytes(seed, iteration).
# Override the run with MICA_FUZZ_SEED / MICA_FUZZ_ITERATIONS; release
# campaigns use fuzz/form_campaign.cr.
private FUZZ_SEED       = (ENV["MICA_FUZZ_SEED"]? || "20261025").to_i64
private FUZZ_ITERATIONS = (ENV["MICA_FUZZ_ITERATIONS"]? || "20000").to_i

describe "Mica::Form fuzzing" do
  it_satisfies({"MICA-FORM-FUZZ", "MICA-FORM-DIFFERENTIAL"}, "survives #{FUZZ_ITERATIONS} seeded hostile mutations (seed #{FUZZ_SEED}) with no crash, overrun, String/IO disagreement or stdlib difference") do
    campaign = Mica::Testing::FuzzCampaign.new(FormFuzz::MUTATOR, FUZZ_SEED, FormFuzz::OVERRUN_SLACK, check_determinism: true)
    default_budget_trips = 0
    report = campaign.run(FUZZ_ITERATIONS) do |bytes, iteration|
      trial = FormFuzz.trial(bytes, iteration)
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
    report.errors_by_class.keys.should contain("Mica::Form::KeySyntaxError")
    report.errors_by_class.keys.should contain("Mica::Form::KeyConflictError")
    report.errors_by_class.keys.should contain("Mica::EncodingError")
  end
end
