#!/usr/bin/ruby
# frozen_string_literal: true

# Runs the YAML benchmark's interleaved A/B rounds and writes the report.
#
#   /usr/bin/ruby bench/yaml/scripts/run_ab.rb --bin bench/bin/yaml --out DIR [--rounds 7] [--seconds 0.25]
#       [--engines flag-emit,stdlib-emit]
#
# Every round measures every engine on every corpus file once, one process
# at a time, with the engine order reversed on alternate rounds, so slow
# drift of the machine lands on all engines alike. A speed is megabytes
# (10^6 bytes) of the YAML file handled per second inside the runner's
# timed loop.
#
# Each Mica engine is compared with the libyaml engine doing the same
# work, round by round (the paired ratio): the report gives the median of
# those ratios, their range, and the absolute MB/s of both sides (median
# over rounds). Per corpus and overall the ratios are combined with the
# geometric mean, and the MB/s by total bytes over total time.
#
# Outputs in DIR: REPORT.md, results.json, samples.tsv (every measurement)
# and run.json (machine, toolchain, libyaml identity, corpus manifest
# hash).
#
# Only the Ruby standard library is used (system /usr/bin/ruby).

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'time'

BENCH_DIR = File.expand_path('..', __dir__)
ROOT = File.expand_path('../..', BENCH_DIR)
MANIFEST_PATH = File.join(BENCH_DIR, 'corpus.tsv')

# Each pair: the Mica engine, the libyaml engine doing the same work, and
# what the pair measures.
LIST_OF_PAIRS = [
  ['mica-events', 'stdlib-events', 'Events: Mica::YAML::PullParser (YAML 1.2) vs YAML::PullParser on libyaml'],
  ['mica-events-libyaml-dialect', 'stdlib-events', 'Events: Mica::YAML::PullParser (libyaml dialect) vs YAML::PullParser on libyaml'],
  ['mica-parse', 'stdlib-parse', 'Values: Mica::YAML.parse_all vs YAML.parse_all on libyaml'],
  ['flag-events', 'stdlib-events', 'Compatibility layer, events: YAML::PullParser built with -Duse_mica vs on libyaml'],
  ['flag-parse', 'stdlib-parse', 'Compatibility layer, values: YAML.parse_all built with -Duse_mica vs on libyaml'],
  ['flag-emit', 'stdlib-emit', 'Compatibility layer, writing: to_yaml (YAML::Builder) built with -Duse_mica vs on libyaml']
].freeze

options = { rounds: 7, seconds: 0.25 }
OptionParser.new do |parser|
  parser.on('--bin DIR') { |value| options[:bin] = value }
  parser.on('--out DIR') { |value| options[:out] = value }
  parser.on('--rounds N', Integer) { |value| options[:rounds] = value }
  parser.on('--seconds S', Float) { |value| options[:seconds] = value }
  parser.on('--engines LIST', Array) { |value| options[:engines] = value }
end.parse!
abort 'usage: run_ab.rb --bin DIR --out DIR [--rounds N] [--seconds S]' unless options[:bin] && options[:out]

bin = File.expand_path(options[:bin])
out = File.expand_path(options[:out])
FileUtils.mkdir_p(out)
has_flag_runner = File.exist?(File.join(bin, 'runner_flag'))

# engine name => [binary, engine argument]
engines = {
  'mica-events' => ['runner', 'mica-events'],
  'mica-events-libyaml-dialect' => ['runner', 'mica-events-libyaml-dialect'],
  'mica-parse' => ['runner', 'mica-parse'],
  'stdlib-events' => ['runner', 'stdlib-events'],
  'stdlib-parse' => ['runner', 'stdlib-parse'],
  'stdlib-emit' => ['runner', 'stdlib-emit']
}
if has_flag_runner
  engines['flag-events'] = ['runner_flag', 'stdlib-events']
  engines['flag-parse'] = ['runner_flag', 'stdlib-parse']
  engines['flag-emit'] = ['runner_flag', 'stdlib-emit']
end
engines.select! { |name, _| options[:engines].include?(name) } if options[:engines]
list_of_pairs = LIST_OF_PAIRS.select { |mica, libyaml, _| engines.key?(mica) && engines.key?(libyaml) }

CorpusFile = Struct.new(:corpus, :name, :path, :bytes)
list_of_files = File.readlines(MANIFEST_PATH, chomp: true).reject { |line| line.empty? || line.start_with?('#') }.map do |line|
  kind, corpus, name, bytes, = line.split("\t", -1)
  path = kind == 'file' ? File.join(BENCH_DIR, 'corpus', corpus, name) : File.join(ROOT, 'bench', 'data', 'yaml', corpus, name)
  CorpusFile.new(corpus, name, path, Integer(bytes))
end

def measure(bin, engine, path, seconds)
  binary, argument = engine
  output, status = Open3.capture2(File.join(bin, binary), argument, path, seconds.to_s)
  abort "#{binary} #{argument} #{path} failed" unless status.success?
  _, bytes, iterations, elapsed, checksum = output.strip.split("\t")
  { mb_per_s: Integer(bytes) * Integer(iterations) / Float(elapsed) / 1e6, checksum: checksum }
end

def median(values)
  sorted = values.sort
  middle = sorted.size / 2
  sorted.size.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2.0
end

def geometric_mean(values)
  Math.exp(values.sum { |value| Math.log(value) } / values.size)
end

samples = Hash.new { |hash, key| hash[key] = [] } # [file name, engine] => MB/s per round
checksums = {}
started = Time.now.utc
File.open(File.join(out, 'samples.tsv'), 'w') do |log|
  log.puts %w[round corpus file engine mb_per_s].join("\t")
  options[:rounds].times do |round|
    order = round.even? ? engines.keys : engines.keys.reverse
    list_of_files.each do |file|
      order.each do |name|
        result = measure(bin, engines[name], file.path, options[:seconds])
        samples[[file.name, name]] << result[:mb_per_s]
        checksums[[file.name, name]] = result[:checksum]
        log.puts [round + 1, file.corpus, file.name, name, result[:mb_per_s].round(2)].join("\t")
      end
    end
    warn "round #{round + 1}/#{options[:rounds]} done"
  end
end

# Engines that read events must agree on what they read in the libyaml
# dialect; a mismatch means the comparison is not like for like.
list_of_files.each do |file|
  expected = checksums[[file.name, 'stdlib-events']] or next
  %w[mica-events-libyaml-dialect flag-events].each do |name|
    actual = checksums[[file.name, name]]
    abort "#{file.name}: #{name} read #{actual}, libyaml read #{expected}" if actual && actual != expected
  end
end

results = { files: [], corpora: {}, overall: {} }
list_of_files.each do |file|
  row = { corpus: file.corpus, name: file.name, bytes: file.bytes, engines: {}, pairs: {} }
  engines.each_key { |name| row[:engines][name] = median(samples[[file.name, name]]).round(1) }
  list_of_pairs.each do |mica, libyaml, _|
    ratios = samples[[file.name, mica]].zip(samples[[file.name, libyaml]]).map { |fast, slow| fast / slow }
    row[:pairs][mica] = { median: median(ratios).round(2), min: ratios.min.round(2), max: ratios.max.round(2) }
  end
  results[:files] << row
end

def combine(rows, list_of_pairs, engines)
  summary = { pairs: {}, engines: {} }
  list_of_pairs.each do |mica, _, _|
    summary[:pairs][mica] = geometric_mean(rows.map { |row| row[:pairs][mica][:median] }).round(2)
  end
  total_bytes = rows.sum { |row| row[:bytes] }
  engines.each_key do |name|
    # Total bytes over total time: the speed of parsing the set once.
    seconds = rows.sum { |row| row[:bytes] / (row[:engines][name] * 1e6) }
    summary[:engines][name] = (total_bytes / seconds / 1e6).round(1)
  end
  summary
end

results[:files].group_by { |row| row[:corpus] }.each { |corpus, rows| results[:corpora][corpus] = combine(rows, list_of_pairs, engines) }
results[:overall] = combine(results[:files], list_of_pairs, engines)
File.write(File.join(out, 'results.json'), JSON.pretty_generate(results))

def capture(*command)
  Open3.capture2e(*command)[0].strip
rescue StandardError => error
  "unavailable (#{error.class})"
end

libyaml_path = capture('otool', '-L', File.join(bin, 'runner')).lines.map(&:split).map(&:first).find { |path| path.to_s.include?('libyaml') }
run = {
  started: started.iso8601,
  finished: Time.now.utc.iso8601,
  rounds: options[:rounds],
  seconds_per_measurement: options[:seconds],
  machine: capture('sysctl', '-n', 'machdep.cpu.brand_string'),
  os: capture('sw_vers', '-productVersion'),
  load_average: capture('sysctl', '-n', 'vm.loadavg'),
  crystal: capture('crystal-alpha', '--version').lines.first.to_s.strip,
  mica_commit: capture('git', '-C', ROOT, 'rev-parse', 'HEAD'),
  libyaml_library: libyaml_path,
  libyaml_sha256: libyaml_path && File.exist?(libyaml_path) ? Digest::SHA256.file(libyaml_path).hexdigest : nil,
  corpus_manifest_sha256: Digest::SHA256.file(MANIFEST_PATH).hexdigest,
  compatibility_layer_measured: has_flag_runner
}
File.write(File.join(out, 'run.json'), JSON.pretty_generate(run))

File.open(File.join(out, 'REPORT.md'), 'w') do |report|
  report.puts '# Mica::YAML vs libyaml benchmark', ''
  report.puts "- Run: #{run[:started]} to #{run[:finished]}, #{run[:rounds]} interleaved rounds, #{run[:seconds_per_measurement]} s per measurement"
  report.puts "- Machine: #{run[:machine]}, macOS #{run[:os]}, load average #{run[:load_average]}"
  report.puts "- Compiler: #{run[:crystal]}; Mica #{run[:mica_commit]}"
  report.puts "- libyaml: #{run[:libyaml_library]} (sha256 #{run[:libyaml_sha256]})"
  report.puts "- Corpus: #{list_of_files.size} files, #{list_of_files.sum(&:bytes)} bytes, manifest sha256 #{run[:corpus_manifest_sha256]}"
  report.puts '', 'A ratio above 1.00 means Mica is faster: "2.00" reads "2.00x as fast as libyaml". MB is 10^6 bytes.', ''
  list_of_pairs.each do |mica, libyaml, title|
    report.puts "## #{title}", ''
    report.puts "Overall: **#{results[:overall][:pairs][mica]}x as fast as libyaml** (geometric mean of the per-file ratios); " \
                "#{results[:overall][:engines][mica]} MB/s against #{results[:overall][:engines][libyaml]} MB/s over the whole corpus.", ''
    report.puts '| Corpus | Ratio (geometric mean) | Mica MB/s | libyaml MB/s |', '|---|---|---|---|'
    results[:corpora].each do |corpus, summary|
      report.puts "| #{corpus} | #{summary[:pairs][mica]} | #{summary[:engines][mica]} | #{summary[:engines][libyaml]} |"
    end
    report.puts '', '| File | Bytes | Ratio (median of paired rounds) | Range | Mica MB/s | libyaml MB/s |', '|---|---|---|---|---|---|'
    results[:files].each do |row|
      pair = row[:pairs][mica]
      report.puts "| #{row[:corpus]}/#{row[:name]} | #{row[:bytes]} | #{pair[:median]} | #{pair[:min]} to #{pair[:max]} | " \
                  "#{row[:engines][mica]} | #{row[:engines][libyaml]} |"
    end
    report.puts ''
  end
end
puts "report: #{File.join(out, 'REPORT.md')}"
