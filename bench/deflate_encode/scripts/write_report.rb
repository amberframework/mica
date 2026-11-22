#!/usr/bin/ruby
# frozen_string_literal: true

# Writes REPORT.md and results.json for a Deflate encoder benchmark run
# directory (run.json, samples.jsonl, memory.jsonl and checks.jsonl from
# run_ab.rb).
#
#   /usr/bin/ruby bench/deflate_encode/scripts/write_report.rb --run DIR [--title TEXT]
#
# Only the Ruby standard library is used (system /usr/bin/ruby).

require 'optparse'
require_relative 'deflate_encode_bench'

run_directory = nil
title = 'Mica Deflate encoders vs system zlib benchmark'
OptionParser.new do |parser|
  parser.banner = 'usage: write_report.rb --run DIR [--title TEXT]'
  parser.on('--run DIR', 'run directory') { |value| run_directory = value }
  parser.on('--title TEXT', 'report title') { |value| title = value }
end.parse!
abort 'write_report.rb: --run DIR is required' unless run_directory

run = JSON.parse(File.read(File.join(run_directory, 'run.json')))
list_of_samples = DeflateBench.read_json_lines(File.join(run_directory, 'samples.jsonl'))
list_of_memory_rows = DeflateBench.read_json_lines(File.join(run_directory, 'memory.jsonl'))
list_of_checks = DeflateBench.read_json_lines(File.join(run_directory, 'checks.jsonl'))
cases = run['cases']
list_of_case_ids = cases.keys.select { |id| list_of_samples.any? { |sample| sample['case_id'] == id } }
list_of_levels = list_of_case_ids.map { |id| cases[id]['level'] }.uniq.sort

# --- per case and engine: absolute numbers over the rounds --------------------
engine_results = {}
list_of_samples.group_by { |sample| [sample['case_id'], sample['engine']] }.each do |(case_id, engine), samples|
  finished = samples.select { |sample| sample['status'] == 'ok' }
  result = { 'rounds' => finished.size, 'failed_rounds' => samples.size - finished.size }
  unless finished.empty?
    megabytes = cases[case_id]['input_bytes'] / 1_000_000.0
    median_seconds = DeflateBench.median(finished.map { |sample| sample['measurement']['median_seconds'] })
    minimum_seconds = finished.map { |sample| sample['measurement']['minimum_seconds'] }.min
    list_of_sizes = finished.map { |sample| sample['measurement']['compressed_bytes'] }.uniq
    result.merge!('median_ms' => median_seconds * 1000, 'minimum_ms' => minimum_seconds * 1000,
                  'median_mb_per_second' => megabytes / median_seconds, 'best_mb_per_second' => megabytes / minimum_seconds,
                  'compressed_bytes' => list_of_sizes.first, 'sizes_agree_across_rounds' => list_of_sizes.size == 1,
                  'samples_per_round' => finished.map { |sample| sample['measurement']['list_of_seconds'].size }.minmax)
  end
  failure = samples.find { |sample| sample['status'] != 'ok' }
  result['error'] = "#{failure['status']}: #{failure['error']}" if failure
  (engine_results[case_id] ||= {})[engine] = result
end
result_of = lambda { |id, engine| (engine_results[id] || {})[engine] || {} }

# --- speed ratios ---------------------------------------------------------------
pairs = {}
DeflateEncodeBench.ratios_of_pairs(list_of_samples).each do |pair_name, ratios_of_case|
  pairs[pair_name] = DeflateBench.paired_bootstrap(ratios_of_case)
  pairs[pair_name]['levels'] = list_of_levels.each_with_object({}) do |level, by_level|
    of_level = ratios_of_case.select { |id, _| cases[id]['level'] == level }
    next if of_level.empty?

    by_level[level.to_s] = DeflateBench.paired_bootstrap(of_level)['geometric_mean'].merge('cases' => of_level.size)
  end
end

# --- sizes ------------------------------------------------------------------------
sizes = {}
list_of_case_ids.each do |id|
  zlib_bytes = result_of.call(id, 'zlib-oneshot')['compressed_bytes'] || result_of.call(id, 'zlib-stream')['compressed_bytes']
  mica_bytes = result_of.call(id, 'mica-oneshot')['compressed_bytes'] || result_of.call(id, 'mica-stream')['compressed_bytes']
  next unless zlib_bytes && mica_bytes

  sizes[id] = { 'zlib_bytes' => zlib_bytes, 'mica_bytes' => mica_bytes, 'ratio' => mica_bytes.to_f / zlib_bytes,
                'mica_stream_bytes' => result_of.call(id, 'mica-stream')['compressed_bytes'],
                'zlib_stream_bytes' => result_of.call(id, 'zlib-stream')['compressed_bytes'] }
end
levels = {}
list_of_levels.each do |level|
  ids = sizes.keys.select { |id| cases[id]['level'] == level }
  next if ids.empty?

  zlib_total = ids.sum { |id| sizes[id]['zlib_bytes'] }
  mica_total = ids.sum { |id| sizes[id]['mica_bytes'] }
  largest = ids.max_by { |id| sizes[id]['ratio'] }
  summary = { 'cases' => ids.size, 'input_bytes' => ids.sum { |id| cases[id]['input_bytes'] }, 'zlib_bytes' => zlib_total,
              'mica_bytes' => mica_total, 'size_ratio' => mica_total.to_f / zlib_total,
              'size_gate_passed' => mica_total.to_f / zlib_total <= DeflateEncodeBench::SIZE_GATE_RATIO,
              'cases_larger_than_zlib' => ids.count { |id| sizes[id]['ratio'] > 1 },
              'largest_case' => { 'id' => largest, 'ratio' => sizes[largest]['ratio'] } }
  pairs.each do |pair_name, pair|
    of_level = pair['cases'].select { |id, _| cases[id]['level'] == level }
    next if of_level.empty?

    slowest_id, slowest = of_level.min_by { |_, interval| interval['ratio'] }
    summary[pair_name] = { 'geometric_mean' => pair['levels'][level.to_s], 'cases' => of_level.size,
                           'cases_at_or_above_zlib' => of_level.count { |_, interval| interval['ratio'] >= DeflateEncodeBench::SPEED_GATE_RATIO },
                           'cases_above_zlib_with_the_whole_interval' => of_level.count { |_, interval| interval['low'] >= DeflateEncodeBench::SPEED_GATE_RATIO },
                           'slowest_case' => { 'id' => slowest_id }.merge(slowest) }
  end
  levels[level.to_s] = summary
end

# --- memory -----------------------------------------------------------------------
peak_rss = {}
encoder_memory = {}
list_of_memory_rows.each do |row|
  next unless row['status'] == 'ok'

  if row['engine'] == 'mica-encoder'
    encoder_memory[row['case_id']] = row['encoder']
  else
    (peak_rss[row['case_id']] ||= {})[row['engine']] = row['peak_rss_bytes'] / 1_048_576.0
  end
end
list_of_failures = list_of_samples.reject { |sample| sample['status'] == 'ok' } +
                   list_of_memory_rows.reject { |row| row['status'] == 'ok' } +
                   list_of_checks.reject { |row| row['status'] == 'ok' }

# --- formatting ---------------------------------------------------------------
def number(value, digits)
  value.nil? ? 'n/a' : format("%.#{digits}f", value)
end

def with_commas(value)
  value.nil? ? 'n/a' : value.to_s.reverse.scan(/\d{1,3}/).join(',').reverse
end

def speed_text(interval)
  interval ? format('%.2f× as fast as zlib [%.2f, %.2f]', interval['ratio'], interval['low'], interval['high']) : 'n/a'
end

def size_text(ratio)
  ratio.nil? ? 'n/a' : format('%.4f (%+.2f%%)', ratio, (ratio - 1) * 100)
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
         "#{list_of_case_ids.size} cases (corpus file x level), each one-shot and streaming, both engines writing one gzip member."
lines << ''
lines << '## Result'
lines << ''
lines << 'The gates of milestone Z2, per level: the corpus total of Mica\'s compressed bytes is at most ' \
         "#{DeflateEncodeBench::SIZE_GATE_RATIO} times zlib's, and Mica is at least as fast as zlib. " \
         'Speed is MB (1,000,000 bytes) of input per second; "N× as fast as zlib" is Mica MB/s over zlib MB/s with its 95% interval.'
lines << ''
rows = levels.map do |level, summary|
  one_shot = summary['one-shot']
  streaming = summary['streaming']
  [level, summary['cases'], with_commas(summary['zlib_bytes']), with_commas(summary['mica_bytes']), size_text(summary['size_ratio']),
   summary['size_gate_passed'] ? 'holds' : '**does not hold**',
   one_shot ? speed_text(one_shot['geometric_mean']) : 'n/a',
   one_shot ? "#{one_shot['cases_at_or_above_zlib']} of #{one_shot['cases']}" : 'n/a',
   streaming ? speed_text(streaming['geometric_mean']) : 'n/a',
   streaming ? "#{streaming['cases_at_or_above_zlib']} of #{streaming['cases']}" : 'n/a']
end
lines << table(['level', 'files', 'zlib bytes (corpus total)', 'Mica bytes', 'Mica / zlib size', 'size gate (at most +1.0%)',
                'one-shot speed, geometric mean', 'one-shot files at or above zlib', 'streaming speed, geometric mean',
                'streaming files at or above zlib'], rows)
lines << ''
levels.each do |level, summary|
  DeflateEncodeBench::LIST_OF_PAIRS.each do |pair_name, _, _|
    pair_summary = summary[pair_name]
    next unless pair_summary

    mean = pair_summary['geometric_mean']
    verdict = if mean['low'] >= DeflateEncodeBench::SPEED_GATE_RATIO
                'holds'
              elsif mean['ratio'] >= DeflateEncodeBench::SPEED_GATE_RATIO
                'holds on the point estimate; the interval reaches below 1.0'
              else
                '**does not hold**'
              end
    slowest = pair_summary['slowest_case']
    lines << "- Level #{level}, #{pair_name}: the geometric-mean speed gate #{verdict} (#{speed_text(mean)}). " \
             "#{pair_summary['cases_at_or_above_zlib']} of #{pair_summary['cases']} files are at or above zlib " \
             "(#{pair_summary['cases_above_zlib_with_the_whole_interval']} with the whole interval); the slowest is `#{slowest['id']}` at #{speed_text(slowest)}."
  end
  largest = summary['largest_case']
  lines << "- Level #{level}, size: #{summary['cases_larger_than_zlib']} of #{summary['cases']} files are larger than zlib's; " \
           "the largest margin is `#{largest['id']}` at #{size_text(largest['ratio'])}."
end
unless list_of_checks.empty?
  passed = list_of_checks.count { |row| row['status'] == 'ok' }
  lines << "- System zlib inflated #{passed} of #{list_of_checks.size} Mica streams (one-shot and streaming, every case) to the original file. " \
           'Every timed sample\'s stream is also decoded by its own library and compared with the input.'
end
unless list_of_one_minute_loads.empty?
  lines << "- Machine load during the timed rounds: 1-minute load average from #{number(list_of_one_minute_loads.min, 1)} to #{number(list_of_one_minute_loads.max, 1)} " \
           "(median #{number(DeflateBench.median(list_of_one_minute_loads), 1)}) on #{run['machine']['cpu_count']} cores. Engines alternate within every round, and ratios pair the two engines inside a round."
end
lines << "- **#{list_of_failures.size} runner processes failed** (see Failures)." unless list_of_failures.empty?
lines << ''
lines << "Intervals are 95% paired-bootstrap intervals over the rounds (#{run['settings']['bootstrap_resamples']} resamples, seed #{run['settings']['bootstrap_seed']})."
lines << ''

DeflateEncodeBench::LIST_OF_PAIRS.each do |pair_name, mica_engine, zlib_engine|
  pair = pairs[pair_name]
  next if pair.nil? || pair['cases'].empty?

  slower = pair['cases'].select { |_, interval| interval['ratio'] < 1 }.sort_by { |_, interval| interval['ratio'] }
  lines << "## Cases where Mica is slower than zlib, #{pair_name} (#{slower.size} of #{pair['cases'].size})"
  lines << ''
  if slower.empty?
    lines << 'None.'
  else
    rows = slower.map do |id, interval|
      [id, number(result_of.call(id, zlib_engine)['median_mb_per_second'], 1), number(result_of.call(id, mica_engine)['median_mb_per_second'], 1),
       speed_text(interval), format('%.1f%% longer', (1 / interval['ratio'] - 1) * 100),
       DeflateEncodeBench.touches_the_gate?(interval) ? 'yes' : 'no']
    end
    lines << table(['case', 'zlib MB/s', 'Mica MB/s', 'speed (95% interval)', 'Mica encode time', 'interval reaches 1.0'], rows)
  end
  lines << ''
end

larger = sizes.select { |_, size| size['ratio'] > 1 }.sort_by { |_, size| -size['ratio'] }
lines << "## Cases where Mica's output is larger than zlib's (#{larger.size} of #{sizes.size})"
lines << ''
if larger.empty?
  lines << 'None.'
else
  lines << table(['case', 'zlib bytes', 'Mica bytes', 'more bytes', 'Mica / zlib size'],
                 larger.map do |id, size|
                   [id, with_commas(size['zlib_bytes']), with_commas(size['mica_bytes']),
                    with_commas(size['mica_bytes'] - size['zlib_bytes']), size_text(size['ratio'])]
                 end)
end
lines << ''

lines << '## Every file, per level'
lines << ''
lines << 'Bytes are the whole gzip member. MB/s is the median over the rounds of each round\'s median encode time. ' \
         'Mica\'s streaming output has the one-shot size unless the last column says otherwise.'
lines << ''
list_of_levels.each do |level|
  lines << "### Level #{level}"
  lines << ''
  rows = list_of_case_ids.select { |id| cases[id]['level'] == level }.map do |id|
    size = sizes[id] || {}
    one_shot = pairs['one-shot'] && pairs['one-shot']['cases'][id]
    streaming = pairs['streaming'] && pairs['streaming']['cases'][id]
    stream_note = size['mica_stream_bytes'] && size['mica_stream_bytes'] != size['mica_bytes'] ? with_commas(size['mica_stream_bytes']) : 'same'
    ["#{cases[id]['corpus']}/#{cases[id]['file']}", with_commas(cases[id]['input_bytes']), with_commas(size['zlib_bytes']),
     with_commas(size['mica_bytes']), size_text(size['ratio']),
     number(result_of.call(id, 'zlib-oneshot')['median_mb_per_second'], 1), number(result_of.call(id, 'mica-oneshot')['median_mb_per_second'], 1),
     speed_text(one_shot),
     number(result_of.call(id, 'zlib-stream')['median_mb_per_second'], 1), number(result_of.call(id, 'mica-stream')['median_mb_per_second'], 1),
     speed_text(streaming), one_shot ? one_shot['rounds'] : 0, stream_note]
  end
  summary = levels[level.to_s]
  if summary
    rows << ['**corpus total / geometric mean**', with_commas(summary['input_bytes']), with_commas(summary['zlib_bytes']),
             with_commas(summary['mica_bytes']), size_text(summary['size_ratio']), '', '',
             summary['one-shot'] ? speed_text(summary['one-shot']['geometric_mean']) : 'n/a', '', '',
             summary['streaming'] ? speed_text(summary['streaming']['geometric_mean']) : 'n/a', '', '']
  end
  lines << table(['file', 'input bytes', 'zlib bytes', 'Mica bytes', 'Mica / zlib size', 'zlib one-shot MB/s', 'Mica one-shot MB/s',
                  'one-shot speed (95% interval)', 'zlib streaming MB/s', 'Mica streaming MB/s', 'streaming speed (95% interval)',
                  'rounds', 'Mica streaming bytes'], rows)
  lines << ''
end

unless encoder_memory.empty? && peak_rss.empty?
  lines << '## Memory'
  lines << ''
  lines << 'A Mica streaming encoder\'s allocation is the collector\'s byte count from before the encoder is built to after the stream is finished, ' \
           'writing to a sink that discards; "tables" is the window, the hash and chain tables and the symbol buffer (the bound is 393,216 bytes, 384 KiB). ' \
           'Peak resident set size is that of a separate process that does one encode (`/usr/bin/time -l`), runtime included: ' \
           'streaming engines read the file in 64 KiB pieces and keep no output; one-shot engines hold the whole input and output.'
  lines << ''
  rows = list_of_levels.map do |level|
    ids = list_of_case_ids.select { |id| cases[id]['level'] == level }
    list_of_encoders = ids.map { |id| encoder_memory[id] }.compact
    stream_rss = lambda do |engine|
      values = ids.map { |id| (peak_rss[id] || {})[engine] }.compact
      values.empty? ? 'n/a' : "#{number(DeflateBench.median(values), 1)} / #{number(values.max, 1)}"
    end
    [level, list_of_encoders.empty? ? 'n/a' : with_commas(list_of_encoders.map { |encoder| encoder['table_bytes'] }.max),
     list_of_encoders.empty? ? 'n/a' : with_commas(list_of_encoders.map { |encoder| encoder['allocated_bytes'] }.max),
     stream_rss.call('mica-stream'), stream_rss.call('zlib-stream'), stream_rss.call('mica-oneshot'), stream_rss.call('zlib-oneshot')]
  end
  lines << table(['level', 'Mica tables, bytes', 'Mica encoder allocation, bytes (largest of the files)',
                  'Mica streaming peak RSS MiB (median / max)', 'zlib streaming peak RSS MiB (median / max)',
                  'Mica one-shot peak RSS MiB (median / max)', 'zlib one-shot peak RSS MiB (median / max)'], rows)
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
    lines << "- `#{failure['engine']}` on `#{failure['case_id']}`#{failure['round'] ? " (round #{failure['round'] + 1})" : ''}: " \
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
lines << '- Both engines write one gzip member (zlib: `deflateInit2` with windowBits 31, memory level 8, the default strategy). ' \
         'One-shot: Mica `Mica::Gzip.encode` against zlib `deflateInit2`, `deflate(Z_FINISH)` into a `deflateBound`-sized buffer allocated for that encode, `deflateEnd`. ' \
         'Streaming: Mica `Mica::Gzip::Writer` against zlib `deflate(Z_NO_FLUSH)` with a 64 KiB output buffer, both fed 64 KiB pieces and both copying their output into one preallocated buffer.'
lines << "- Each (round, case, engine) is its own release-built process, one at a time: 1 warm-up encode, then up to #{run['settings']['samples']} timed samples, stopping once the timed encodes add up to #{run['settings']['sample_budget_seconds']} s. " \
         'An encode under 10 ms is timed in batches of the size that reaches 10 ms; an encode of 0.5 s or more is not repeated for a warm-up (its first run is its first sample). ' \
         'The first stream of a process is decoded by the engine\'s own library and compared with the input, and every later stream must equal the first byte for byte.'
lines << "- Rounds: #{run['settings']['base_rounds']} base rounds; a case whose 95% interval reaches 1.0 runs up to #{run['settings']['max_rounds']}. " \
         'Even rounds run the engines in the listed order (Mica before its zlib pair), odd rounds in the reverse order.'
lines << ''

File.write(File.join(run_directory, 'REPORT.md'), lines.join("\n"))
results = {
  'title' => title, 'run' => run,
  'gates' => { 'size_ratio_at_most' => DeflateEncodeBench::SIZE_GATE_RATIO, 'speed_ratio_at_least' => DeflateEncodeBench::SPEED_GATE_RATIO },
  'levels' => levels, 'pairs' => pairs, 'sizes' => sizes, 'engine_results' => engine_results,
  'peak_rss_mib' => peak_rss, 'encoder_memory' => encoder_memory, 'cases' => cases,
  'zlib_checks' => { 'passed' => list_of_checks.count { |row| row['status'] == 'ok' }, 'total' => list_of_checks.size },
  'list_of_failures' => list_of_failures
}
File.write(File.join(run_directory, 'results.json'), JSON.pretty_generate(results))
warn "wrote #{File.join(run_directory, 'REPORT.md')} and results.json"
exit 1 unless list_of_failures.empty?
