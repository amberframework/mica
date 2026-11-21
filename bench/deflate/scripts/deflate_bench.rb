# frozen_string_literal: true

# Shared by run_ab.rb and write_report.rb: the corpus manifest, the engine
# table and the statistics. Ruby standard library only (system /usr/bin/ruby).

require 'json'

module DeflateBench
  BENCH_DIR = File.expand_path('..', __dir__)
  ROOT = File.expand_path('../..', BENCH_DIR)
  MANIFEST_PATH = File.join(BENCH_DIR, 'corpus.tsv')

  # engine => the runner program that holds it
  RUNNER_OF_ENGINE = {
    'mica-oneshot' => 'mica_runner',
    'zlib-oneshot-fresh' => 'zlib_runner',
    'zlib-oneshot-reused' => 'zlib_runner',
    'mica-stream' => 'mica_runner',
    'zlib-stream' => 'zlib_runner',
    'stdlib-reader' => 'stdlib_runner'
  }.freeze
  # [name, Mica engine, zlib engine]: the pairs a speed ratio is computed for.
  # 'one-shot' is the gate: zlib allocates a new output buffer per decode, as
  # Mica's one-shot API does. 'one-shot, zlib reusing one buffer' is zlib's
  # best case, reported beside it.
  LIST_OF_PAIRS = [
    ['one-shot', 'mica-oneshot', 'zlib-oneshot-fresh'],
    ['streaming', 'mica-stream', 'zlib-stream'],
    ['one-shot, zlib reusing one buffer', 'mica-oneshot', 'zlib-oneshot-reused']
  ].freeze
  # The pairs whose intervals decide the extra rounds.
  LIST_OF_ROUND_DECIDING_PAIRS = %w[one-shot streaming].freeze
  FILE_EXTENSION_OF_FORMAT = { 'gzip' => 'gz', 'zlib' => 'zz', 'deflate' => 'deflate' }.freeze
  LIST_OF_GATE_BOUNDS = [0.5, 1.0].freeze
  INTERIM_GATE_RATIO = 0.5
  BOOTSTRAP_RESAMPLES = 10_000
  BOOTSTRAP_SEED = 20_261_121

  CorpusFile = Struct.new(:corpus, :name, :path, :bytes, :sha256, :source)

  # The benchmark inputs: every `file` and `http` row of corpus.tsv.
  def self.list_of_corpus_files(data_dir)
    File.readlines(MANIFEST_PATH, chomp: true).reject { |line| line.empty? || line.start_with?('#') }.map do |line|
      kind, corpus, name, bytes, sha256, source = line.split("\t", -1)
      next if kind == 'archive'

      directory = kind == 'http' ? File.join(BENCH_DIR, 'corpus', 'http') : File.join(data_dir, corpus)
      CorpusFile.new(corpus, name, File.join(directory, name), Integer(bytes), sha256, source)
    end.compact
  end

  def self.median(list)
    sorted = list.sort
    middle = sorted.size / 2
    sorted.size.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2.0
  end

  def self.geometric_mean(list)
    Math.exp(list.sum { |value| Math.log(value) } / list.size)
  end

  def self.percentile(sorted, fraction)
    position = fraction * (sorted.size - 1)
    low = position.floor
    high = position.ceil
    sorted[low] + (sorted[high] - sorted[low]) * (position - low)
  end

  # The paired bootstrap of speed ratios.
  #
  # `ratios_of_case` maps a case id to its per-round ratios (Mica MB/s over
  # zlib MB/s, both measured in that round, one after the other). A case's
  # ratio is the geometric mean of its rounds; the overall ratio is the
  # geometric mean of the cases. Each resample draws rounds with
  # replacement, the same draws for every case (a case with fewer rounds
  # maps the draws onto its own), so load shared by a round stays paired.
  # Returns { 'cases' => { id => {ratio, low, high, rounds} },
  # 'geometric_mean' => {ratio, low, high} } with 95% percentile intervals.
  def self.paired_bootstrap(ratios_of_case, resamples: BOOTSTRAP_RESAMPLES, seed: BOOTSTRAP_SEED)
    return { 'cases' => {}, 'geometric_mean' => nil } if ratios_of_case.empty?

    list_of_ids = ratios_of_case.keys
    list_of_logs = list_of_ids.map { |id| ratios_of_case[id].map { |ratio| Math.log(ratio) } }
    most_rounds = list_of_logs.map(&:size).max
    random = Random.new(seed)
    resampled_means_of_case = Array.new(list_of_ids.size) { Array.new(resamples) }
    resampled_overall = Array.new(resamples)
    resamples.times do |resample|
      list_of_draws = Array.new(most_rounds) { random.rand }
      total = 0.0
      list_of_logs.each_with_index do |logs, index|
        rounds = logs.size
        sum = 0.0
        rounds.times { |round| sum += logs[(list_of_draws[round] * rounds).to_i] }
        mean = sum / rounds
        resampled_means_of_case[index][resample] = mean
        total += mean
      end
      resampled_overall[resample] = total / list_of_ids.size
    end
    cases = {}
    list_of_ids.each_with_index do |id, index|
      cases[id] = interval_of(list_of_logs[index].sum / list_of_logs[index].size, resampled_means_of_case[index])
                  .merge('rounds' => list_of_logs[index].size)
    end
    overall = list_of_logs.sum { |logs| logs.sum / logs.size } / list_of_logs.size
    { 'cases' => cases, 'geometric_mean' => interval_of(overall, resampled_overall) }
  end

  def self.interval_of(log_ratio, list_of_resampled_logs)
    sorted = list_of_resampled_logs.sort
    { 'ratio' => Math.exp(log_ratio), 'low' => Math.exp(percentile(sorted, 0.025)),
      'high' => Math.exp(percentile(sorted, 0.975)) }
  end

  # True when the interval reaches one of the gate's bounds (0.5x or 1.0x),
  # so more rounds could change which side of it the ratio is on.
  def self.touches_a_bound?(interval)
    LIST_OF_GATE_BOUNDS.any? { |bound| interval['low'] <= bound && bound <= interval['high'] }
  end

  # samples: the parsed lines of samples.jsonl. Returns, per pair name,
  # { case id => [ratio per round where both engines finished] }.
  def self.ratios_of_pairs(list_of_samples)
    by_key = {}
    list_of_samples.each do |sample|
      next unless sample['status'] == 'ok'

      by_key[[sample['case_id'], sample['round'], sample['engine']]] = sample['measurement']['median_seconds']
    end
    LIST_OF_PAIRS.each_with_object({}) do |(pair_name, mica_engine, zlib_engine), ratios_of_pair|
      ratios_of_case = Hash.new { |hash, key| hash[key] = [] }
      by_key.each do |(case_id, round, engine), mica_seconds|
        next unless engine == mica_engine

        zlib_seconds = by_key[[case_id, round, zlib_engine]]
        ratios_of_case[case_id] << zlib_seconds / mica_seconds if zlib_seconds
      end
      ratios_of_pair[pair_name] = ratios_of_case
    end
  end

  def self.read_json_lines(path)
    return [] unless File.file?(path)

    File.readlines(path, chomp: true).reject(&:empty?).map { |line| JSON.parse(line) }
  end
end
