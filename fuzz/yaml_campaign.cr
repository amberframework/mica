# Release-build differential campaign over Mica::YAML against libyaml (see
# fuzz/yaml_fuzz.cr).
#
#   crystal-alpha build --release fuzz/yaml_campaign.cr -o bin/yaml_campaign
#   MICA_YAML_SUITE=conformance/yaml-test-suite bin/yaml_campaign SEED ITERATIONS [FIRST]
#
# Prints one summary line (cases; agreements, both-reject, disagreements
# and rejection differences; crashes; per generator family; the highest
# operations per input byte; seconds), then the error messages that
# differ between two rejections, each family of rejection difference with
# its count and one replayable example, and one FAIL line per
# disagreement or crash, each replayable as SEED:ITERATION. Exits 1 when a
# disagreement, a rejection difference or a crash was found.
#
# `yaml_campaign SEED replay ITERATION` prints one case, both event
# streams and the verdict.
require "./yaml_fuzz"

usage = "usage: yaml_campaign SEED ITERATIONS [FIRST] | yaml_campaign SEED replay ITERATION"
seed = (ARGV[0]? || abort(usage)).to_i64
mutator = YAMLFuzz.mutator(YAMLFuzz.list_of_seeds)

if ARGV[1]? == "replay"
  kase = YAMLFuzz.case_for(mutator, seed, (ARGV[2]? || abort(usage)).to_i)
  puts "family: #{kase.family}", "input: #{String.new(kase.bytes).inspect}", "hex: #{kase.bytes.hexstring}"
  oracle = YAMLOracle.parse(kase.bytes)
  puts "libyaml:", oracle.list_of_events.join("\n"), "libyaml error: #{oracle.error.inspect}"
  list_of_events, error, _ = YAMLFuzz.parse_with_mica(kase.bytes, Mica::YAML::Dialect::LibYAML)
  puts "mica:", list_of_events.join("\n"), "mica error: #{error ? YAMLFuzz.describe_error(error).inspect : "nil"}"
  trial = YAMLFuzz.trial(kase.bytes)
  puts "verdict: #{trial.verdict} #{trial.detail}", "yaml12: #{trial.strict_outcome}"
  exit
end

iterations = (ARGV[1]? || abort(usage)).to_i
first = (ARGV[2]? || "0").to_i
started = Time.instant
counts = Hash(YAMLFuzz::Verdict, Int32).new(0)
families = Hash(YAMLFuzz::Family, Int32).new(0)
family_agreements = Hash(YAMLFuzz::Family, Int32).new(0)
classifications = Hash(String, Int32).new(0)
classification_examples = {} of String => String
error_differences = Hash(String, Int32).new(0)
error_difference_examples = {} of String => String
list_of_failures = [] of String
list_of_crashes = [] of String
max_ratio = 0.0
same_errors = 0
strict_accepts = 0

iterations.times do |offset|
  iteration = first + offset
  id = "#{seed}:#{iteration}"
  begin
    kase = YAMLFuzz.case_for(mutator, seed, iteration)
    trial = YAMLFuzz.trial(kase.bytes)
  rescue error
    list_of_crashes << "#{id} #{error.class}: #{error.message.to_s[0, 200]}"
    next
  end
  counts[trial.verdict] += 1
  families[kase.family] += 1
  family_agreements[kase.family] += 1 if trial.verdict.agree?
  strict_accepts += 1 if trial.strict_outcome.starts_with?("accept")
  if trial.units >= 256
    ratio = trial.operations / trial.units
    max_ratio = ratio if ratio > max_ratio
  end
  case trial.verdict
  when .disagree?
    list_of_failures << "#{id} #{trial.detail}"
  when .only_mica_rejects?, .only_oracle_rejects?
    classifications[trial.classification] += 1
    classification_examples[trial.classification] ||= "#{id} #{trial.detail}"
  when .both_reject?
    if trial.same_error
      same_errors += 1
    else
      key = trial.detail.gsub(/\d+:\d+/, "L:C")
      error_differences[key] += 1
      error_difference_examples[key] ||= id
    end
  else
    # agreements need no record
  end
end
elapsed = Time.instant - started

rejection_differences = counts[YAMLFuzz::Verdict::OnlyMicaRejects] + counts[YAMLFuzz::Verdict::OnlyOracleRejects]
puts "seed=#{seed} first=#{first} cases=#{iterations} agree=#{counts[YAMLFuzz::Verdict::Agree]} " \
     "both_reject=#{counts[YAMLFuzz::Verdict::BothReject]} (same_error=#{same_errors}) " \
     "disagreements=#{counts[YAMLFuzz::Verdict::Disagree]} only_mica_rejects=#{counts[YAMLFuzz::Verdict::OnlyMicaRejects]} " \
     "only_libyaml_rejects=#{counts[YAMLFuzz::Verdict::OnlyOracleRejects]} crashes=#{list_of_crashes.size} " \
     "yaml12_accepts=#{strict_accepts} max_ops_per_byte=#{max_ratio.round(2)} seconds=#{elapsed.total_seconds.round(1)} " \
     "libyaml=#{YAMLOracle.version}"
puts "  families: " + families.map { |family, count| "#{family}=#{count} (agree #{family_agreements[family]})" }.join(" ")
classifications.to_a.sort_by! { |pair| -pair[1] }.each do |name, count|
  puts "  rejection difference: #{name}: #{count} (e.g. #{classification_examples[name]})"
end
error_differences.to_a.sort_by! { |pair| -pair[1] }.first(40).each do |name, count|
  puts "  error text differs: #{name}: #{count} (e.g. #{error_difference_examples[name]})"
end
list_of_failures.first(50).each { |line| puts "  FAIL disagreement #{line}" }
list_of_crashes.first(50).each { |line| puts "  FAIL crash #{line}" }
exit(list_of_failures.empty? && list_of_crashes.empty? && rejection_differences == 0 ? 0 : 1)
