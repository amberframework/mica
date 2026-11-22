# Release-build round-trip campaign over the Mica::Deflate, Mica::Zlib and
# Mica::Gzip encoders (see fuzz/deflate_encode_fuzz.cr): each case encodes
# a generated input in one call and through the Writer, and the system
# zlib and Mica's decoder must both return the input from both streams.
#
#   crystal-alpha build --release fuzz/deflate_encode_campaign.cr -o bin/deflate_encode_campaign
#   bin/deflate_encode_campaign SEED ITERATIONS [FIRST]
#
# Prints one summary line (cases, streams verified, failures, input bytes,
# seconds, the zlib version), then what the generators covered and one
# FAIL line per failure, each replayable as SEED:ITERATION. Exits 1 when
# any case failed.
require "./deflate_encode_fuzz"

usage = "usage: deflate_encode_campaign SEED ITERATIONS [FIRST]"
seed = (ARGV[0]? || abort(usage)).to_i64
iterations = (ARGV[1]? || abort(usage)).to_i
first = (ARGV[2]? || "0").to_i

started = Time.instant
report = DeflateEncodeFuzz.run(seed, iterations, first)
elapsed = Time.instant - started

puts "seed=#{seed} first=#{first} #{report} seconds=#{elapsed.total_seconds.round(1)} zlib=#{DeflateOracle.version}"
puts "  coverage: #{report.coverage}"
report.list_of_failures.first(50).each { |line| puts "  FAIL #{line}" }
exit(report.clean? ? 0 : 1)
