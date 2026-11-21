#!/usr/bin/ruby
# frozen_string_literal: true

# Writes REPORT.md and results.json for an Inflate benchmark run directory
# (run.json, samples.jsonl and memory.jsonl from run_ab.rb).
#
#   /usr/bin/ruby bench/deflate/scripts/write_report.rb --run DIR [--title TEXT]
#
# Only the Ruby standard library is used (system /usr/bin/ruby).

require 'optparse'
require_relative 'deflate_bench'

run_directory = nil
title = 'Mica Inflate vs system zlib benchmark'
OptionParser.new do |parser|
  parser.banner = 'usage: write_report.rb --run DIR [--title TEXT]'
  parser.on('--run DIR', 'run directory') { |value| run_directory = value }
  parser.on('--title TEXT', 'report title') { |value| title = value }
end.parse!
abort 'write_report.rb: --run DIR is required' unless run_directory

run = JSON.parse(File.read(File.join(run_directory, 'run.json')))
list_of_samples = DeflateBench.read_json_lines(File.join(run_directory, 'samples.jsonl'))
list_of_memory_rows = DeflateBench.read_json_lines(File.join(run_directory, 'memory.jsonl'))
cases = run['cases']
list_of_case_ids = cases.keys.select { |id| list_of_samples.any? { |sample| sample['case_id'] == id } }
list_of_engines = DeflateBench::RUNNER_OF_ENGINE.keys.select { |engine| list_of_samples.any? { |sample| sample['engine'] == engine } }

# --- per case and engine: absolute numbers over the rounds --------------------
engine_results = {}
list_of_samples.group_by { |sample| [sample['case_id'], sample['engine']] }.each do |(case_id, engine), samples|
  finished = samples.select { |sample| sample['status'] == 'ok' }
  result = { 'rounds' => finished.size, 'failed_rounds' => samples.size - finished.size }
  unless finished.empty?
    megabytes = cases[case_id]['output_bytes'] / 1_000_000.0
    median_seconds = DeflateBench.median(finished.map { |sample| sample['measurement']['median_seconds'] })
    minimum_seconds = finished.map { |sample| sample['measurement']['minimum_seconds'] }.min
    result.merge!('median_ms' => median_seconds * 1000, 'minimum_ms' => minimum_seconds * 1000,
                  'median_mb_per_second' => megabytes / median_seconds, 'best_mb_per_second' => megabytes / minimum_seconds,
                  'iterations_per_sample' => finished.last['measurement']['iterations_per_sample'])
  end
  failure = samples.find { |sample| sample['status'] != 'ok' }
  result['error'] = "#{failure['status']}: #{failure['error']}" if failure
  (engine_results[case_id] ||= {})[engine] = result
end
memory = {}
list_of_memory_rows.each do |row|
  (memory[row['case_id']] ||= {})[row['engine']] = row['status'] == 'ok' ? row['peak_rss_bytes'] / 1_048_576.0 : nil
end

# --- ratios -------------------------------------------------------------------
pairs = {}
DeflateBench.ratios_of_pairs(list_of_samples).each do |pair_name, ratios_of_case|
  pairs[pair_name] = DeflateBench.paired_bootstrap(ratios_of_case)
  groups = ratios_of_case.keys.group_by { |id| cases[id]['corpus'] }.merge(ratios_of_case.keys.group_by { |id| "format #{cases[id]['format']}" })
  pairs[pair_name]['groups'] = groups.each_with_object({}) do |(group, ids), by_group|
    by_group[group] = DeflateBench.paired_bootstrap(ratios_of_case.select { |id, _| ids.include?(id) })['geometric_mean']
                                  .merge('cases' => ids.size)
  end
end
gate = pairs['one-shot'] && pairs['one-shot']['geometric_mean']
gate_passed = gate && gate['ratio'] >= DeflateBench::INTERIM_GATE_RATIO
list_of_failures = list_of_samples.reject { |sample| sample['status'] == 'ok' } +
                   list_of_memory_rows.reject { |row| row['status'] == 'ok' }

# --- formatting ---------------------------------------------------------------
def number(value, digits)
  value.nil? ? 'n/a' : format("%.#{digits}f", value)
end

def milliseconds(value)
  return 'n/a' if value.nil?

  value >= 10 ? format('%.1f', value) : format('%.4f', value)
end

def ratio_text(interval)
  interval ? format('%.3fx [%.3f, %.3f]', interval['ratio'], interval['low'], interval['high']) : 'n/a'
end

def gap_text(ratio)
  if ratio >= 1
    format('Mica is %.2fx as fast as zlib (%.0f%% faster)', ratio, (ratio - 1) * 100)
  else
    format('Mica runs at %.2fx zlib\'s speed: zlib is %.2fx as fast, and a Mica decode takes %.0f%% longer', ratio, 1 / ratio,
           (1 / ratio - 1) * 100)
  end
end

def table(list_of_headers, list_of_rows)
  lines = ["| #{list_of_headers.join(' | ')} |", "|#{list_of_headers.map { '---' }.join('|')}|"]
  list_of_rows.each { |row| lines << "| #{row.join(' | ')} |" }
  lines.join("\n")
end

list_of_round_loads = run['list_of_round_loads'] || []
list_of_one_minute_loads = list_of_samples.map { |sample| sample['load_average'] && sample['load_average'][0] }.compact
lines = []
lines << "# #{title}"
lines << ''
lines << "Run directory `#{File.basename(run_directory)}`, started #{run['started_at']}, finished #{run['finished_at'] || 'not yet'}. " \
         "#{list_of_case_ids.size} cases (corpus file x format), engines: #{list_of_engines.join(', ')}."
lines << ''
lines << '## Result'
lines << ''
if gate
  lines << "- **Interim gate (geometric mean >= #{DeflateBench::INTERIM_GATE_RATIO}x zlib one-shot, zlib allocating a new output buffer per decode): #{gate_passed ? 'PASSED' : 'NOT MET'}.** " \
           "Mica one-shot / zlib one-shot (fresh buffer), geometric mean over #{pairs['one-shot']['cases'].size} cases: **#{ratio_text(gate)}** (ratio, 95% interval)."
  lines << "- The gap, plainly: #{gap_text(gate['ratio'])}."
  streaming = pairs['streaming'] && pairs['streaming']['geometric_mean']
  lines << "- Streaming (Mica Reader / zlib streaming, 64 KiB buffers), geometric mean over #{pairs['streaming']['cases'].size} cases: **#{ratio_text(streaming)}**. #{gap_text(streaming['ratio'])}." if streaming
  reused = pairs['one-shot, zlib reusing one buffer'] && pairs['one-shot, zlib reusing one buffer']['geometric_mean']
  lines << "- Against zlib's best case (one-shot into one buffer reused by every decode), geometric mean over #{pairs['one-shot, zlib reusing one buffer']['cases'].size} cases: **#{ratio_text(reused)}**. #{gap_text(reused['ratio'])}." if reused
  slower = pairs['one-shot']['cases'].count { |_, interval| interval['ratio'] < 1 }
  lines << "- Mica one-shot is slower than zlib one-shot (fresh buffer) on #{slower} of #{pairs['one-shot']['cases'].size} cases (listed below with margins)."
else
  lines << '- **No Mica measurements in this run**: the interim gate (geometric mean >= 0.5x zlib one-shot) is not evaluated. The zlib rows below are the baseline alone.'
end
unless list_of_one_minute_loads.empty?
  lines << "- Machine load during the run: 1-minute load average from #{number(list_of_one_minute_loads.min, 1)} to #{number(list_of_one_minute_loads.max, 1)} " \
           "(median #{number(DeflateBench.median(list_of_one_minute_loads), 1)}) on #{run['machine']['cpu_count']} cores. Engines alternate within every round, and ratios pair the two engines inside a round."
end
lines << "- **#{list_of_failures.size} runner processes failed** (see Failures)." unless list_of_failures.empty?
lines << ''
lines << 'Ratios are Mica MB/s over zlib MB/s: above 1 Mica is faster. MB is 1,000,000 bytes of decoded output. ' \
         'Intervals are 95% paired-bootstrap intervals over the rounds ' \
         "(#{run['settings']['bootstrap_resamples']} resamples, seed #{run['settings']['bootstrap_seed']})."
lines << ''

pairs.each do |pair_name, pair|
  next if pair['cases'].empty?

  lines << "## Geometric means, #{pair_name}"
  lines << ''
  rows = [['all cases', pair['cases'].size, ratio_text(pair['geometric_mean'])]]
  pair['groups'].each { |group, interval| rows << [group, interval['cases'], ratio_text(interval)] }
  lines << table(['group', 'cases', 'Mica / zlib (95% interval)'], rows)
  lines << ''
end

DeflateBench::LIST_OF_PAIRS.each do |pair_name, mica_engine, zlib_engine|
  pair = pairs[pair_name]
  next if pair.nil? || pair['cases'].empty?

  slower = pair['cases'].select { |_, interval| interval['ratio'] < 1 }.sort_by { |_, interval| interval['ratio'] }
  lines << "## Cases where Mica is slower than zlib, #{pair_name} (#{slower.size} of #{pair['cases'].size})"
  lines << ''
  if slower.empty?
    lines << 'None.'
  else
    rows = slower.map do |id, interval|
      mica = engine_results[id][mica_engine]
      zlib = engine_results[id][zlib_engine]
      [id, number(zlib['median_mb_per_second'], 1), number(mica['median_mb_per_second'], 1), ratio_text(interval),
       format('%.0f%% longer', (1 / interval['ratio'] - 1) * 100), DeflateBench.touches_a_bound?(interval) ? 'yes' : 'no']
    end
    lines << table(['case', 'zlib MB/s', 'Mica MB/s', 'ratio (95% interval)', 'Mica decode time', 'interval reaches 0.5x or 1.0x'], rows)
  end
  lines << ''
end

lines << '## Every case: absolute numbers'
lines << ''
lines << 'Per engine: the median over the rounds of each round\'s median decode time, the fastest sample of any round, ' \
         'and MB/s of decoded output from each. `in` is the compressed size, `out` the decoded size, in bytes.'
lines << ''
DeflateBench::LIST_OF_PAIRS.each do |pair_name, mica_engine, zlib_engine|
  next unless list_of_engines.include?(zlib_engine)

  lines << "### #{pair_name}: #{zlib_engine} and #{mica_engine}"
  lines << ''
  rows = list_of_case_ids.map do |id|
    zlib = (engine_results[id] || {})[zlib_engine] || {}
    mica = (engine_results[id] || {})[mica_engine] || {}
    interval = pairs[pair_name] && pairs[pair_name]['cases'][id]
    [id, cases[id]['compressed_bytes'], cases[id]['output_bytes'],
     milliseconds(zlib['median_ms']), milliseconds(zlib['minimum_ms']), number(zlib['median_mb_per_second'], 1), number(zlib['best_mb_per_second'], 1),
     milliseconds(mica['median_ms']), milliseconds(mica['minimum_ms']), number(mica['median_mb_per_second'], 1), number(mica['best_mb_per_second'], 1),
     ratio_text(interval), interval ? interval['rounds'] : (zlib['rounds'] || 0)]
  end
  lines << table(['case', 'in', 'out', 'zlib median ms', 'zlib min ms', 'zlib MB/s', 'zlib best MB/s', 'Mica median ms', 'Mica min ms',
                  'Mica MB/s', 'Mica best MB/s', 'Mica / zlib (95% interval)', 'rounds'], rows)
  lines << ''
end
if list_of_engines.include?('stdlib-reader')
  lines << '### Context: Crystal stdlib readers (`Compress::Gzip::Reader` and siblings, 64 KiB slice)'
  lines << ''
  rows = list_of_case_ids.map do |id|
    stdlib = (engine_results[id] || {})['stdlib-reader'] || {}
    [id, milliseconds(stdlib['median_ms']), milliseconds(stdlib['minimum_ms']), number(stdlib['median_mb_per_second'], 1),
     number(stdlib['best_mb_per_second'], 1), stdlib['rounds'] || 0]
  end
  lines << table(['case', 'median ms', 'min ms', 'MB/s', 'best MB/s', 'rounds'], rows)
  lines << ''
end

unless memory.empty?
  lines << '## Peak memory'
  lines << ''
  lines << 'Maximum resident set size of a separate process that does one verified decode (`/usr/bin/time -l`), in MiB. ' \
           'One-shot engines hold the whole input and the whole output; streaming engines read the file and hash 64 KiB chunks.'
  lines << ''
  rows = list_of_case_ids.map do |id|
    [id, number(cases[id]['compressed_bytes'] / 1_048_576.0, 2), number(cases[id]['output_bytes'] / 1_048_576.0, 2)] +
      list_of_engines.map { |engine| number((memory[id] || {})[engine], 1) }
  end
  lines << table(['case', 'in MiB', 'out MiB'] + list_of_engines, rows)
  lines << ''
end

lines << '## Load averages'
lines << ''
lines << 'The machine is shared. The load average (1, 5 and 15 minutes) at the start of each block of rounds:'
lines << ''
lines << table(['round', 'UTC time', 'cases in the block', '1 min', '5 min', '15 min'],
               list_of_round_loads.map do |load|
                 [load['round'] + 1, load['at'], load['cases']] + load['load_average'].map { |value| number(value, 1) }
               end)
lines << ''

unless list_of_failures.empty?
  lines << '## Failures'
  lines << ''
  list_of_failures.first(50).each do |failure|
    lines << "- `#{failure['engine']}` on `#{failure['case_id']}`#{failure['round'] ? " (round #{failure['round'] + 1})" : ' (peak-memory process)'}: " \
             "#{failure['status']}: #{(failure['error'] || '').lines.first.to_s.strip}"
  end
  lines << "- and #{list_of_failures.size - 50} more (results.json)" if list_of_failures.size > 50
  lines << ''
end

machine = run['machine']
zlib = run['zlib']
lines << '## Method, machine and toolchain'
lines << ''
lines << "- Machine: #{machine['cpu']}, #{machine['cpu_count']} cores, macOS #{machine['macos_version']} (build #{machine['macos_build']})."
lines << "- Toolchain: #{run['toolchain']['crystal_alpha'].to_s.lines.first.to_s.strip}; runners built with `--release`."
lines << "- zlib: `zlibVersion()` #{zlib['zlib_version']}; #{zlib['library']} (dyld_info UUID #{zlib['dyld_info_uuid']}); " \
         "SDK libz.tbd sha256 #{zlib['sdk_libz_tbd_sha256']}. The Mica runner links no libz."
lines << "- Mica: branch #{run['git']['branch']} at commit #{run['git']['commit']}#{run['git']['status'].to_s.empty? ? '' : ', with uncommitted changes in the working tree (run.json lists them)'}; sha256 over src/ #{run['git']['src_sha256']}."
lines << "- Inputs: each corpus file compressed once by system zlib at level #{run['settings']['compression_level']} as gzip (windowBits 31), zlib (15) and raw DEFLATE (-15); " \
         'the sha256 of every compressed input is in results.json (`cases`).'
lines << "- Each (round, case, engine) is its own release-built process, one at a time: 1 warm-up decode, then #{run['settings']['samples']} timed samples. " \
         'A decode under 10 ms is timed in batches of the size that reaches 10 ms. Every sample\'s output is hashed after its clock stops and must equal the original file\'s sha256.'
lines << "- Rounds: #{run['settings']['base_rounds']} base rounds; a case whose 95% interval reaches 0.5x or 1.0x (every case, when the geometric mean's does) runs up to #{run['settings']['max_rounds']}. " \
         'Even rounds run the engines in the listed order (Mica before its zlib pair), odd rounds in the reverse order.'
lines << "- `zlib-oneshot-fresh` (the gate's baseline) allocates an untouched output buffer of the known size from the collector for every decode, as Mica one-shot allocates the `Bytes` it returns; `zlib-oneshot-reused` inflates into one buffer allocated when the process starts (zlib's best case). " \
         'Streaming engines read the input from memory through their own buffers, hand out chunks of at most 64 KiB, and copy them into one preallocated buffer.'
lines << '- Mica decodes with `Mica::Deflate::DecodeLimits::TRUSTED_ASSET` and `timeout: nil`.'
lines << ''

File.write(File.join(run_directory, 'REPORT.md'), lines.join("\n"))
results = {
  'title' => title, 'run' => run,
  'gate' => { 'threshold' => DeflateBench::INTERIM_GATE_RATIO, 'passed' => gate ? gate_passed : nil, 'geometric_mean' => gate },
  'pairs' => pairs, 'engine_results' => engine_results, 'peak_rss_mib' => memory, 'cases' => cases,
  'list_of_failures' => list_of_failures
}
File.write(File.join(run_directory, 'results.json'), JSON.pretty_generate(results))
warn "wrote #{File.join(run_directory, 'REPORT.md')} and results.json"
exit 1 unless list_of_failures.empty?
