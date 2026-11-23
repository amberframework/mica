# Interleaved A/B rounds of the Brotli encode benchmark: each engine in its
# own release-built process, the order alternating every round, at the
# qualities given, on the plain files of prepare_corpus.rb's corpus.
#
#   /usr/bin/ruby bench/brotli/encode_ab.rb CORPUS_DIR MICA_RUNNER REF_RUNNER QUALITIES ROUNDS OUT.json
require "json"

dir, mica, ref, qualities, rounds, out = ARGV
qualities = qualities.split(",").map(&:to_i)
rounds = rounds.to_i
names = File.readlines(File.join(dir, "cases.tsv")).map { |line| line.split("\t")[0] }.uniq
cases = []
samples = Hash.new { |hash, key| hash[key] = { "mica" => [], "ref" => [] } }
sizes = Hash.new { |hash, key| hash[key] = {} }
log = File.open(out.sub(/\.json\z/, ".log"), "w")
rounds.times do |round|
  log.puts "#{Time.now.utc.strftime("%H:%M:%SZ")} round #{round + 1}, load #{`sysctl -n vm.loadavg`.strip}"
  log.flush
  qualities.each do |quality|
    names.each do |name|
      file = File.join(dir, "plain", name)
      raw = File.size(file)
      cases << [name, quality, raw, 0] if round.zero?
      budget = quality >= 10 ? 2_000_000 : 20_000_000
      reps = [[budget / [raw, 1].max, 3].max, 200].min
      engines = round.even? ? %w[mica ref] : %w[ref mica]
      engines.each do |engine|
        line = IO.popen([engine == "mica" ? mica : ref, file, quality.to_s, reps.to_s], &:read)
        size, *times = line.split.map(&:to_i)
        sorted = times.sort
        samples["#{name}.q#{quality}"][engine] << sorted[sorted.size / 2]
        sizes["#{name}.q#{quality}"][engine] = size
      end
    end
  end
end
File.write(out, JSON.pretty_generate({ "mode" => "encode", "rounds" => rounds, "cases" => cases, "samples" => samples,
                                       "sizes" => sizes, "host" => `hostname`.strip,
                                       "cpu" => `sysctl -n machdep.cpu.brand_string`.strip }))
log.puts "done"
