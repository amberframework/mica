# Release-build run of the engine-internal differential (see
# fuzz/regex_engine_differential.cr).
#
#   crystal-alpha build --release fuzz/regex_engine_campaign.cr -o bin/regex_engine_campaign
#   bin/regex_engine_campaign SEED PATTERNS [FIRST]
#
# Each accepted pattern is searched over 5,461 haystacks, so 367 accepted
# patterns make two million cases. Prints one summary line and every
# disagreement (replayable as SEED:INDEX); exits 1 when any was found.
require "./regex_engine_differential"

usage = "usage: regex_engine_campaign SEED PATTERNS [FIRST]"
seed = (ARGV[0]? || abort(usage)).to_i64
patterns = (ARGV[1]? || abort(usage)).to_i
first = (ARGV[2]? || "0").to_i

started = Time.instant
report = EngineDifferential.run(seed, patterns, first)
elapsed = Time.instant - started
puts "seed=#{seed} first=#{first} patterns=#{report.patterns} refused=#{report.refused} cases=#{report.cases} " \
     "disagreements=#{report.list_of_disagreements.size} seconds=#{elapsed.total_seconds.round(1)}"
report.list_of_disagreements.each { |line| puts "  FAIL #{line}" }
exit(report.list_of_disagreements.empty? ? 0 : 1)
