# frozen_string_literal: true

# Shared by run_ab.rb and write_report.rb of the Deflate encoder benchmark:
# the cases, the engine table and the gates. The corpus manifest and the
# statistics (paired bootstrap, geometric mean) are the Inflate
# benchmark's (bench/deflate/scripts/deflate_bench.rb). Ruby standard
# library only (system /usr/bin/ruby).

require_relative '../../deflate/scripts/deflate_bench'

module DeflateEncodeBench
  BENCH_DIR = File.expand_path('..', __dir__)
  ROOT = DeflateBench::ROOT

  # engine => the runner program that holds it
  RUNNER_OF_ENGINE = {
    'mica-oneshot' => 'mica_runner',
    'zlib-oneshot' => 'zlib_runner',
    'mica-stream' => 'mica_runner',
    'zlib-stream' => 'zlib_runner'
  }.freeze
  # [name, Mica engine, zlib engine]: the pairs a speed ratio is computed for.
  LIST_OF_PAIRS = [
    ['one-shot', 'mica-oneshot', 'zlib-oneshot'],
    ['streaming', 'mica-stream', 'zlib-stream']
  ].freeze
  LIST_OF_LEVELS = [1, 6, 9].freeze
  # The gates of milestone Z2: at each level the corpus total of Mica's
  # compressed bytes is at most 1.01 times zlib's, and Mica is at least as
  # fast as zlib.
  SIZE_GATE_RATIO = 1.01
  SPEED_GATE_RATIO = 1.0

  # A real HTTP body measured with the corpus but kept out of the
  # repository (bench/deflate/corpus.tsv says why). It joins the cases when
  # the file is present, and must have this size and sha256.
  LOCAL_ONLY_FILE = DeflateBench::CorpusFile.new(
    'http', 'json_1m.json', File.join(DeflateBench::BENCH_DIR, 'corpus', 'http', 'json_1m.json'), 955_337,
    '5b38eea3e5ed63ffa5ce047b4542fc140212e69c4c0c05823359bdc6708e0a13', 'local file, not committed'
  )

  # The benchmark inputs: the Inflate corpus plus the local-only body.
  def self.list_of_corpus_files(data_dir)
    list = DeflateBench.list_of_corpus_files(data_dir)
    list << LOCAL_ONLY_FILE if File.file?(LOCAL_ONLY_FILE.path)
    list
  end

  def self.case_id(corpus_file, level)
    "#{corpus_file.corpus}/#{corpus_file.name}:L#{level}"
  end

  # samples: the parsed lines of samples.jsonl. Returns, per pair name,
  # { case id => [Mica MB/s over zlib MB/s per round where both finished] }.
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

  # True when the interval reaches the speed gate, so more rounds could
  # change which side of it the ratio is on.
  def self.touches_the_gate?(interval)
    interval['low'] <= SPEED_GATE_RATIO && SPEED_GATE_RATIO <= interval['high']
  end
end
