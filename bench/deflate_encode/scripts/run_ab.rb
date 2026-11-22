#!/usr/bin/ruby
# frozen_string_literal: true

# The interleaved A/B driver of the Deflate encoder benchmark
# (docs/benchmarks.md, "Deflate encoders"). bench/deflate_encode/run.sh
# calls it after the fetch and the builds.
#
#   /usr/bin/ruby bench/deflate_encode/scripts/run_ab.rb --bin bench/bin/deflate_encode --out DIR [options]
#
# For every case (corpus file x level) it
#   1. checks Mica's streams with system zlib: the Mica runner writes its
#      one-shot and streaming gzip members to files and the zlib runner
#      must inflate each to the original (checks.jsonl);
#   2. measures memory: one `once` process per engine under
#      /usr/bin/time -l (peak resident set size), and the bytes a Mica
#      streaming encoder allocates (memory.jsonl);
#   3. runs the timed rounds: in each round every engine measures the case
#      in its own process, one process at a time, in the engine order in
#      even rounds (Mica before its zlib pair) and the reverse in odd
#      rounds, with the load average recorded per round and per sample;
#   4. after the base rounds, runs every case whose 95% interval over the
#      base rounds reaches 1.0x up to --max-rounds.
#
# The run directory is resumable: a (round, case, engine) sample already in
# samples.jsonl is kept, so a long run is split into pieces with --corpora,
# --levels, --only or a growing --rounds against the same --out.
# write_report.rb turns the directory into REPORT.md and results.json.
#
# Only the Ruby standard library is used (system /usr/bin/ruby).

require 'digest'
require 'fileutils'
require 'optparse'
require 'time'
require_relative 'deflate_encode_bench'

options = {
  bin: File.join(DeflateEncodeBench::ROOT, 'bench/bin/deflate_encode'),
  data: File.join(DeflateEncodeBench::ROOT, 'bench/data/deflate'),
  out: nil,
  corpora: %w[canterbury silesia http],
  levels: DeflateEncodeBench::LIST_OF_LEVELS,
  engines: DeflateEncodeBench::RUNNER_OF_ENGINE.keys,
  rounds: 5,
  max_rounds: 0,
  samples: 11,
  budget: 1.5,
  only: nil,
  timeout: 600,
  memory: true,
  checks: true
}
OptionParser.new do |parser|
  parser.banner = 'usage: run_ab.rb --out DIR [options]'
  parser.on('--bin DIR', 'directory of the release-built runners') { |value| options[:bin] = value }
  parser.on('--data DIR', 'bench/data/deflate') { |value| options[:data] = value }
  parser.on('--out DIR', 'run directory (resumed when it has samples)') { |value| options[:out] = value }
  parser.on('--corpora LIST', 'canterbury,silesia,http') { |value| options[:corpora] = value.split(',') }
  parser.on('--levels LIST', '1,6,9') { |value| options[:levels] = value.split(',').map { |level| Integer(level) } }
  parser.on('--engines LIST', DeflateEncodeBench::RUNNER_OF_ENGINE.keys.join(',')) { |value| options[:engines] = value.split(',') }
  parser.on('--rounds N', Integer, 'base rounds (default 5)') { |value| options[:rounds] = value }
  parser.on('--max-rounds N', Integer, 'rounds for cases whose interval reaches 1.0 (default: the base rounds)') do |value|
    options[:max_rounds] = value
  end
  parser.on('--samples N', Integer, 'most timed samples per process (default 11)') { |value| options[:samples] = value }
  parser.on('--budget SECONDS', Float, 'timed seconds per process after which sampling stops (default 1.5)') do |value|
    options[:budget] = value
  end
  parser.on('--only TEXT', 'only case ids containing TEXT (id: corpus/file:L<level>)') { |value| options[:only] = value }
  parser.on('--timeout SECONDS', Integer, 'stop a runner process after this long (default 600)') do |value|
    options[:timeout] = value
  end
  parser.on('--skip-memory', 'skip the memory processes') { options[:memory] = false }
  parser.on('--skip-checks', 'skip the zlib checks of Mica\'s streams') { options[:checks] = false }
end.parse!
abort 'run_ab.rb: --out DIR is required' unless options[:out]
unknown_engines = options[:engines] - DeflateEncodeBench::RUNNER_OF_ENGINE.keys
abort "run_ab.rb: unknown engines #{unknown_engines.join(', ')}" unless unknown_engines.empty?
options[:max_rounds] = [options[:max_rounds], options[:rounds]].max

RUN_DIR = File.expand_path(options[:out])
BIN_DIR = File.expand_path(options[:bin])
DATA_DIR = File.expand_path(options[:data])
SAMPLES_PATH = File.join(RUN_DIR, 'samples.jsonl')
MEMORY_PATH = File.join(RUN_DIR, 'memory.jsonl')
CHECKS_PATH = File.join(RUN_DIR, 'checks.jsonl')
LOG_PATH = File.join(RUN_DIR, 'run.log')
FileUtils.mkdir_p(RUN_DIR)

def log(message)
  line = "#{Time.now.utc.strftime('%H:%M:%SZ')} #{message}"
  warn line
  File.open(LOG_PATH, 'a') { |file| file.puts(line) }
end

def load_average
  `/usr/sbin/sysctl -n vm.loadavg`.scan(/\d+\.\d+/).map(&:to_f)
end

def output_of(*command)
  output = IO.popen(command, err: %i[child out], &:read)
  $?.success? ? output.strip : nil
rescue SystemCallError
  nil
end

# Runs one process to completion or to the timeout. Returns
# [stdout, stderr, :ok | :failed | :timeout].
def run_process(list_of_arguments, timeout_seconds)
  stdout_path = File.join(RUN_DIR, '.stdout')
  stderr_path = File.join(RUN_DIR, '.stderr')
  pid = Process.spawn(*list_of_arguments, out: stdout_path, err: stderr_path)
  waiter = Process.detach(pid)
  outcome =
    if waiter.join(timeout_seconds)
      waiter.value.success? ? :ok : :failed
    else
      Process.kill('KILL', pid)
      waiter.join
      :timeout
    end
  [File.read(stdout_path), File.read(stderr_path), outcome]
end

runner_path_of = lambda { |engine| File.join(BIN_DIR, DeflateEncodeBench::RUNNER_OF_ENGINE.fetch(engine)) }
mica_runner = File.join(BIN_DIR, 'mica_runner')
zlib_runner = File.join(BIN_DIR, 'zlib_runner')
[mica_runner, zlib_runner].each do |path|
  abort "run_ab.rb: #{path} is missing; bench/deflate_encode/run.sh builds it" unless File.executable?(path)
end
zlib_version = output_of(zlib_runner, 'zlib-version') || abort('run_ab.rb: zlib_runner zlib-version failed')

# --- cases --------------------------------------------------------------------
Case = Struct.new(:id, :corpus, :file, :level, :path, :input_bytes, :input_sha256)

list_of_cases = []
DeflateEncodeBench.list_of_corpus_files(DATA_DIR).each do |corpus_file|
  next unless options[:corpora].include?(corpus_file.corpus)

  abort "run_ab.rb: #{corpus_file.path} is missing; run bench/deflate/scripts/fetch_corpus.rb" unless File.file?(corpus_file.path)
  actual_sha256 = Digest::SHA256.file(corpus_file.path).hexdigest
  unless actual_sha256 == corpus_file.sha256
    abort "run_ab.rb: #{corpus_file.path} has sha256 #{actual_sha256}, the corpus pins #{corpus_file.sha256}"
  end
  options[:levels].each do |level|
    id = DeflateEncodeBench.case_id(corpus_file, level)
    next if options[:only] && !id.include?(options[:only])

    list_of_cases << Case.new(id, corpus_file.corpus, corpus_file.name, level, corpus_file.path, corpus_file.bytes,
                              corpus_file.sha256)
  end
end
abort 'run_ab.rb: no cases selected' if list_of_cases.empty?
log "#{list_of_cases.size} cases, engines #{options[:engines].join(', ')}, zlib #{zlib_version}"

# --- run.json: machine, toolchain, zlib identity, inputs ---------------------
run_path = File.join(RUN_DIR, 'run.json')
run = File.file?(run_path) ? JSON.parse(File.read(run_path)) : { 'started_at' => Time.now.utc.iso8601, 'list_of_invocations' => [] }
sdk_path = output_of('/usr/bin/xcrun', '--show-sdk-path')
libz_tbd = sdk_path && File.join(sdk_path, 'usr/lib/libz.tbd')
run['machine'] = {
  'macos_version' => output_of('/usr/bin/sw_vers', '-productVersion'),
  'macos_build' => output_of('/usr/bin/sw_vers', '-buildVersion'),
  'cpu' => output_of('/usr/sbin/sysctl', '-n', 'machdep.cpu.brand_string'),
  'cpu_count' => output_of('/usr/sbin/sysctl', '-n', 'hw.ncpu'),
  'memory_bytes' => output_of('/usr/sbin/sysctl', '-n', 'hw.memsize')
}
run['toolchain'] = { 'crystal_alpha' => output_of('crystal-alpha', '--version') }
run['zlib'] = {
  'zlib_version' => zlib_version,
  'library' => '/usr/lib/libz.1.dylib',
  'dyld_info_uuid' => (output_of('/usr/bin/dyld_info', '-uuid', '/usr/lib/libz.1.dylib') || '')[/\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/],
  'sdk_libz_tbd' => libz_tbd,
  'sdk_libz_tbd_sha256' => libz_tbd && File.file?(libz_tbd) ? Digest::SHA256.file(libz_tbd).hexdigest : nil,
  'linked_by_runner' => %w[zlib_runner mica_runner].each_with_object({}) do |name, linked|
    linked[name] = (output_of('/usr/bin/otool', '-L', File.join(BIN_DIR, name)) || '').lines.grep(/libz/).map(&:strip)
  end
}
unless run['zlib']['linked_by_runner']['zlib_runner'].any? { |line| line.start_with?('/usr/lib/libz.1.dylib') }
  abort 'run_ab.rb: zlib_runner does not link /usr/lib/libz.1.dylib; the baseline must be the system zlib'
end
abort 'run_ab.rb: mica_runner links libz; the Mica runner must link none' unless run['zlib']['linked_by_runner']['mica_runner'].empty?
# The commit, tree state and runner binaries are those of the invocation
# that started the run directory. A later invocation records its own in
# list_of_invocations and must find the same runner binaries, so one run
# directory never mixes two builds.
git_now = {
  'commit' => output_of('git', '-C', DeflateEncodeBench::ROOT, 'rev-parse', 'HEAD'),
  'branch' => output_of('git', '-C', DeflateEncodeBench::ROOT, 'rev-parse', '--abbrev-ref', 'HEAD'),
  'status' => output_of('git', '-C', DeflateEncodeBench::ROOT, 'status', '--short'),
  # Identifies the measured source even when the working tree has uncommitted changes.
  'src_sha256' => Digest::SHA256.hexdigest(
    Dir.glob(File.join(DeflateEncodeBench::ROOT, 'src/**/*.cr')).sort.map do |path|
      "#{path.sub(DeflateEncodeBench::ROOT, '')} #{Digest::SHA256.file(path).hexdigest}\n"
    end.join
  )
}
runner_sha256_now = Dir.children(BIN_DIR).grep(/_runner\z/).sort.each_with_object({}) do |name, hashes|
  hashes[name] = Digest::SHA256.file(File.join(BIN_DIR, name)).hexdigest
end
run['git'] ||= git_now
run['runner_sha256'] ||= runner_sha256_now
unless run['runner_sha256'] == runner_sha256_now
  abort "run_ab.rb: the runners in #{BIN_DIR} are not the ones #{RUN_DIR} was started with; use a new --out for a new build"
end
run['settings'] = { 'base_rounds' => options[:rounds], 'max_rounds' => options[:max_rounds], 'samples' => options[:samples],
                    'sample_budget_seconds' => options[:budget], 'engines' => options[:engines],
                    'bootstrap_resamples' => DeflateBench::BOOTSTRAP_RESAMPLES, 'bootstrap_seed' => DeflateBench::BOOTSTRAP_SEED,
                    'container' => 'gzip' }
run['cases'] ||= {}
list_of_cases.each do |one_case|
  run['cases'][one_case.id] = { 'corpus' => one_case.corpus, 'file' => one_case.file, 'level' => one_case.level,
                                'input_bytes' => one_case.input_bytes, 'input_sha256' => one_case.input_sha256 }
end
run['list_of_round_loads'] ||= []
run['list_of_invocations'] << { 'at' => Time.now.utc.iso8601, 'arguments' => ARGV.dup, 'only' => options[:only],
                                'corpora' => options[:corpora], 'levels' => options[:levels], 'load_average' => load_average,
                                'git_commit' => git_now['commit'], 'src_sha256' => git_now['src_sha256'] }
save_run = lambda { File.write(run_path, JSON.pretty_generate(run)) }
save_run.call

# --- Mica's streams, checked by system zlib ------------------------------------
if options[:checks]
  checked = DeflateBench.read_json_lines(CHECKS_PATH).map { |row| [row['case_id'], row['engine']] }
  stream_path = File.join(RUN_DIR, '.stream.gz')
  File.open(CHECKS_PATH, 'a') do |file|
    list_of_cases.each do |one_case|
      (options[:engines] & %w[mica-oneshot mica-stream]).each do |engine|
        next if checked.include?([one_case.id, engine])

        _, write_error, written = run_process([mica_runner, 'write', engine, one_case.level.to_s, one_case.path, stream_path],
                                              options[:timeout])
        row = { 'case_id' => one_case.id, 'engine' => engine }
        if written == :ok
          row['compressed_bytes'] = File.size(stream_path)
          row['compressed_sha256'] = Digest::SHA256.file(stream_path).hexdigest
          _, check_error, outcome = run_process([zlib_runner, 'check', 'zlib-oneshot', stream_path, one_case.path], options[:timeout])
          row['status'] = outcome.to_s
          row['error'] = check_error.strip[0, 2000] unless outcome == :ok
        else
          row['status'] = written.to_s
          row['error'] = write_error.strip[0, 2000]
        end
        log "FAILED zlib check of #{engine} #{one_case.id}: #{row['error'].to_s.lines.first}" unless row['status'] == 'ok'
        file.puts(JSON.generate(row))
        file.flush
      end
    end
  end
  FileUtils.rm_f(stream_path)
  log 'Mica streams checked by system zlib'
end

# --- memory -------------------------------------------------------------------
if options[:memory]
  measured = DeflateBench.read_json_lines(MEMORY_PATH).map { |row| [row['case_id'], row['engine']] }
  File.open(MEMORY_PATH, 'a') do |file|
    list_of_cases.each do |one_case|
      options[:engines].each do |engine|
        next if measured.include?([one_case.id, engine])

        stdout, stderr, outcome = run_process(['/usr/bin/time', '-l', runner_path_of.call(engine), 'once', engine,
                                               one_case.level.to_s, one_case.path], options[:timeout])
        peak = stderr[/(\d+)\s+maximum resident set size/, 1]
        row = { 'case_id' => one_case.id, 'engine' => engine, 'status' => outcome.to_s }
        if outcome == :ok && peak
          row['peak_rss_bytes'] = peak.to_i
          row['encode'] = JSON.parse(stdout)
        else
          row['error'] = stderr.lines.reject { |line| line =~ /^\s+\d/ }.join.strip[0, 2000]
          log "FAILED once #{engine} #{one_case.id}: #{row['error'].lines.first}"
        end
        file.puts(JSON.generate(row))
        file.flush
      end
      next if measured.include?([one_case.id, 'mica-encoder']) || !options[:engines].include?('mica-stream')

      stdout, stderr, outcome = run_process([mica_runner, 'memory', one_case.level.to_s, one_case.path], options[:timeout])
      row = { 'case_id' => one_case.id, 'engine' => 'mica-encoder', 'status' => outcome.to_s }
      if outcome == :ok
        row['encoder'] = JSON.parse(stdout)
      else
        row['error'] = stderr.strip[0, 2000]
      end
      file.puts(JSON.generate(row))
      file.flush
    end
  end
  log 'memory measured'
end

# --- timed rounds -------------------------------------------------------------
# Even rounds run each pair Mica first, odd rounds zlib first (the whole
# order is reversed), so neither engine always follows the other.
def engine_order(list_of_engines, round)
  round.even? ? list_of_engines : list_of_engines.reverse
end

list_of_samples = DeflateBench.read_json_lines(SAMPLES_PATH)
finished = {}
list_of_samples.each { |sample| finished[[sample['round'], sample['case_id'], sample['engine']]] = true }
started = Time.now
processes_run = 0

run_round = lambda do |round, list_of_round_cases|
  pending = list_of_round_cases.reject do |one_case|
    options[:engines].all? { |engine| finished[[round, one_case.id, engine]] }
  end
  next if pending.empty?

  round_load = load_average
  run['list_of_round_loads'] << { 'round' => round, 'at' => Time.now.utc.iso8601, 'load_average' => round_load,
                                  'cases' => pending.size }
  save_run.call
  log "round #{round + 1}: #{pending.size} cases, load average #{round_load.join(' ')}"
  File.open(SAMPLES_PATH, 'a') do |file|
    pending.each do |one_case|
      engine_order(options[:engines], round).each do |engine|
        next if finished[[round, one_case.id, engine]]

        stdout, stderr, outcome = run_process([runner_path_of.call(engine), 'measure', engine, one_case.level.to_s, one_case.path,
                                               one_case.input_sha256, options[:samples].to_s, options[:budget].to_s],
                                              options[:timeout])
        sample = { 'round' => round, 'case_id' => one_case.id, 'engine' => engine, 'status' => outcome.to_s,
                   'load_average' => load_average }
        if outcome == :ok
          sample['measurement'] = JSON.parse(stdout)
        else
          sample['error'] = stderr.strip[0, 2000]
          log "FAILED #{engine} #{one_case.id} (#{outcome}): #{sample['error'].lines.first}"
        end
        file.puts(JSON.generate(sample))
        file.flush
        list_of_samples << sample
        finished[[round, one_case.id, engine]] = true
        processes_run += 1
      end
    end
  end
  log "round #{round + 1} done, #{(Time.now - started).round}s since the rounds began"
end

options[:rounds].times { |round| run_round.call(round, list_of_cases) }

# Cases that need the extra rounds: a 95% interval that reaches 1.0x. The
# decision uses the base rounds only, over every case in the run
# directory, so resuming or splitting the extra rounds extends the same
# cases each time.
if options[:max_rounds] > options[:rounds]
  base_samples = list_of_samples.select { |sample| sample['round'] < options[:rounds] }
  extended_ids = []
  DeflateEncodeBench.ratios_of_pairs(base_samples).each_value do |ratios_of_case|
    result = DeflateBench.paired_bootstrap(ratios_of_case)
    extended_ids |= result['cases'].select { |_, interval| DeflateEncodeBench.touches_the_gate?(interval) }.keys
  end
  extended_cases = list_of_cases.select { |one_case| extended_ids.include?(one_case.id) }
  unless extended_cases.empty?
    log "#{extended_cases.size} of the selected cases have a 95% interval that reaches 1.0x: running rounds #{options[:rounds] + 1} to #{options[:max_rounds]} for them"
    (options[:rounds]...options[:max_rounds]).each { |round| run_round.call(round, extended_cases) }
  end
end

run['finished_at'] = Time.now.utc.iso8601
run['list_of_invocations'].last['finished_load_average'] = load_average
save_run.call
FileUtils.rm_f([File.join(RUN_DIR, '.stdout'), File.join(RUN_DIR, '.stderr')])
log "done: #{processes_run} runner processes this invocation"
