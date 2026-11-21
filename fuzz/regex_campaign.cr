# Release-build fuzz campaign over Mica::Regex::Syntax.
#
#   crystal-alpha build --release fuzz/regex_campaign.cr -o bin/regex_campaign
#   bin/regex_campaign SEED ITERATIONS [FIRST]
#
# Prints one summary line, the error classes, then every crash, budget
# overrun and nondeterministic case (each replayable as SEED:ITERATION).
# Exits 1 when any was found.
require "./regex_fuzz"

seed = (ARGV[0]? || abort("usage: regex_campaign SEED ITERATIONS [FIRST]")).to_i64
iterations = (ARGV[1]? || abort("usage: regex_campaign SEED ITERATIONS [FIRST]")).to_i
first = (ARGV[2]? || "0").to_i

campaign = Mica::Testing::FuzzCampaign.new(RegexFuzz::MUTATOR, seed, RegexFuzz::OVERRUN_SLACK, check_determinism: true)
started = Time.instant
report = campaign.run(iterations, first) { |bytes, iteration| RegexFuzz.trial(bytes, seed, iteration) }
elapsed = Time.instant - started
puts "seed=#{seed} first=#{first} #{report} seconds=#{elapsed.total_seconds.round(1)}"
report.errors_by_class.to_a.sort_by!(&.[0]).each { |name, count| puts "  #{name}: #{count}" }
(report.list_of_crashes + report.list_of_budget_overruns + report.list_of_nondeterministic_cases).first(50).each { |line| puts "  FAIL #{line}" }
exit(report.clean? ? 0 : 1)
