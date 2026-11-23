# Interleaved A/B rounds of the Brotli decode benchmark. Each engine runs
# in its own release-built process; the engine order alternates every
# round; ratios pair the two engines inside a round.
#
#   /usr/bin/ruby bench/brotli/run_ab.rb CORPUS_DIR MICA_RUNNER REF_RUNNER MODE ROUNDS OUT.json
require "json"

dir, mica, ref, mode, rounds, out = ARGV
rounds = rounds.to_i
cases = File.readlines(File.join(dir, "cases.tsv")).map { |l| n, q, raw, br = l.split("\t"); [n, q.to_i, raw.to_i, br.to_i] }
samples = Hash.new { |h, k| h[k] = { "mica" => [], "ref" => [] } }
log = File.open(out.sub(/\.json\z/, ".log"), "w")
rounds.times do |round|
  load = `sysctl -n vm.loadavg`.strip
  log.puts "#{Time.now.utc.strftime("%H:%M:%SZ")} round #{round + 1}, load #{load}"
  log.flush
  cases.each do |name, quality, raw, _|
    file = File.join(dir, "#{name}.q#{quality}.br")
    reps = [[20_000_000 / [raw, 1].max, 5].max, 400].min
    engines = round.even? ? %w[mica ref] : %w[ref mica]
    engines.each do |engine|
      command = engine == "mica" ? [mica, mode, file, reps.to_s] : [ref, mode, file, reps.to_s, raw.to_s]
      line = IO.popen(command, &:read)
      size, *times = line.split.map(&:to_i)
      abort "#{engine} decoded #{size} bytes of #{name}, expected #{raw}" unless size == raw
      sorted = times.sort
      samples["#{name}.q#{quality}"][engine] << sorted[sorted.size / 2]
    end
  end
end
File.write(out, JSON.pretty_generate({ "mode" => mode, "rounds" => rounds, "cases" => cases, "samples" => samples,
                                       "host" => `hostname`.strip, "cpu" => `sysctl -n machdep.cpu.brand_string`.strip }))
log.puts "done"
