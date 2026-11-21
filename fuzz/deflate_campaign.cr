# Release-build differential campaign over Mica::Deflate, Mica::Zlib and
# Mica::Gzip against the system zlib (see fuzz/deflate_fuzz.cr).
#
#   crystal-alpha build --release fuzz/deflate_campaign.cr -o bin/deflate_campaign
#   bin/deflate_campaign SEED ITERATIONS [FIRST]
#
# Prints one summary line (cases, agreements, both-reject, disagreements,
# cases whose Reader error differs from the one-shot error, and crashes; per generator family and per container as
# cases/agreements/both-reject/disagreements; seconds), then what the
# generators covered, the error tallies, and one FAIL line per
# disagreement, streaming difference, crash or wrongly generated case, each replayable as
# SEED:ITERATION. Exits 1 when any was found.
#
# With MICA_DEFLATE_SAVE_DIR set, every failing input is minimized and
# written there as <container>-<seed>-<iteration>.bin (and its preset
# dictionary, when it has one, as ...-dictionary.bin).
require "./deflate_fuzz"

usage = "usage: deflate_campaign SEED ITERATIONS [FIRST]"
seed = (ARGV[0]? || abort(usage)).to_i64
iterations = (ARGV[1]? || abort(usage)).to_i
first = (ARGV[2]? || "0").to_i
save_directory = ENV["MICA_DEFLATE_SAVE_DIR"]?

started = Time.instant
saved = 0
report = DeflateFuzz.run(seed, iterations, first) do |id, kase, _trial|
  next unless save_directory
  next if saved >= 50
  saved += 1
  minimized = DeflateFuzz.minimize(kase, {seed, id.split(':')[1].to_i})
  stem = File.join(save_directory, "#{kase.format.to_s.downcase}-#{id.tr(":", "-")}")
  Dir.mkdir_p(save_directory)
  File.write("#{stem}.bin", minimized.bytes)
  if dictionary = kase.dictionary
    File.write("#{stem}-dictionary.bin", dictionary)
  end
end
elapsed = Time.instant - started

puts "seed=#{seed} first=#{first} #{report} seconds=#{elapsed.total_seconds.round(1)} zlib=#{DeflateOracle.version}"
puts "  coverage: #{report.coverage}"
puts "  oracle rejections: #{report.oracle_rejections.to_a.sort_by!(&.[0]).map { |name, count| "#{name}=#{count}" }.join(" ")}"
report.mica_errors.to_a.sort_by!(&.[0]).each { |name, count| puts "  #{name}: #{count}" }
report.notes.to_a.sort_by!(&.[0]).each { |note, count| puts "  note: #{note}: #{count}" }
report.list_of_note_examples.each { |line| puts "  note example: #{line}" }
report.list_of_disagreements.first(50).each { |line| puts "  FAIL disagreement #{line}" }
report.streaming_differences.to_a.sort_by!(&.[0]).each { |difference, count| puts "  streaming: #{difference}: #{count}" }
report.list_of_streaming_differences.first(50).each { |line| puts "  FAIL streaming #{line}" }
report.list_of_crashes.first(50).each { |line| puts "  FAIL crash #{line}" }
report.list_of_rejected_valid_cases.first(50).each { |line| puts "  FAIL generator #{line}" }
exit(report.clean? ? 0 : 1)
