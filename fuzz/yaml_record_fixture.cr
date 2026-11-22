# Records what libyaml makes of a fixed set of fuzz cases, for
# spec/yaml/libyaml_replay_spec.cr (which replays them through Mica's
# libyaml dialect without linking libyaml).
#
#   MICA_YAML_SUITE=conformance/yaml-test-suite/data \
#     crystal-alpha run fuzz/yaml_record_fixture.cr -- spec/yaml/fixtures/libyaml_events.tsv
#
# Each row is `<input as hex> TAB ok|error TAB <events joined by " | ", or
# the error text>`, in the notation of fuzz/yaml_oracle.cr. Cases libyaml
# rejects for their bytes (invalid UTF-8, control characters) are left
# out: libyaml reports those ahead of the parse position, so the text
# before the error differs by design.
require "./yaml_fuzz"

SEED  = 20_261_122_i64
ROWS  =            800
BYTES =            300

path = ARGV[0]? || abort "usage: yaml_record_fixture.cr OUTPUT_TSV"
abort "MICA_YAML_SUITE must point at the yaml-test-suite data directory" unless ENV["MICA_YAML_SUITE"]?
mutator = YAMLFuzz.mutator(YAMLFuzz.list_of_seeds)
rows = 0
iteration = 0
File.open(path, "w") do |file|
  file << "# libyaml " << YAMLOracle.version << ", fuzz seed " << SEED << " (see fuzz/yaml_record_fixture.cr)\n"
  while rows < ROWS
    kase = YAMLFuzz.case_for(mutator, SEED, iteration)
    iteration += 1
    next if kase.bytes.size > BYTES || kase.bytes.empty?
    oracle = YAMLOracle.parse(kase.bytes)
    next if oracle.error_kind == 2
    if error = oracle.error
      # Two of every three rejected cases are skipped, to keep the fixture
      # weighted toward documents that parse.
      next unless iteration % 3 == 0
      file << kase.bytes.hexstring << "\terror\t" << error << '\n'
    else
      file << kase.bytes.hexstring << "\tok\t" << oracle.list_of_events.join(" | ") << '\n'
    end
    rows += 1
  end
end
puts "#{rows} rows from #{iteration} cases in #{path}"
