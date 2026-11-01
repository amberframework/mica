# Release-build fuzz campaign over Mica::XML.
#
#   crystal-alpha build --release fuzz/campaign.cr -o bin/fuzz_campaign
#   bin/fuzz_campaign SEED ITERATIONS [FIRST]
#
# Prints one summary line, then every crash, budget overrun and
# nondeterministic case (each replayable as SEED:ITERATION). Exits 1 when
# any was found.
require "./xml_fuzz"

seed = (ARGV[0]? || abort("usage: campaign SEED ITERATIONS [FIRST]")).to_i64
iterations = (ARGV[1]? || abort("usage: campaign SEED ITERATIONS [FIRST]")).to_i
first = (ARGV[2]? || "0").to_i

campaign = Mica::Testing::FuzzCampaign.new(XMLFuzz::MUTATOR, seed, XMLFuzz::OVERRUN_SLACK, check_determinism: true)
started = Time.instant
default_budget_trips = 0
report = campaign.run(iterations, first) do |bytes, iteration|
  trial = XMLFuzz.trial(bytes, iteration)
  error = trial.error
  if iteration % 4 != 3 && (error.is_a?(Mica::WorkBudgetExceededError) || error.is_a?(Mica::DeadlineExceededError))
    default_budget_trips += 1
  end
  trial
end
elapsed = Time.instant - started
puts "seed=#{seed} first=#{first} #{report} default_budget_trips=#{default_budget_trips} seconds=#{elapsed.total_seconds.round(1)}"
report.errors_by_class.to_a.sort_by!(&.[0]).each { |name, count| puts "  #{name}: #{count}" }
(report.list_of_crashes + report.list_of_budget_overruns + report.list_of_nondeterministic_cases).first(50).each { |line| puts "  FAIL #{line}" }
exit(report.clean? && default_budget_trips == 0 ? 0 : 1)
