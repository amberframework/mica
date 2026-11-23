#!/usr/bin/ruby
# frozen_string_literal: true

# Interleaved A/B rounds of HPACK decoding: Mica (bench/hpack/mica_runner.cr)
# against nghttp2 1.71.0 (bench/hpack/nghttp2_runner.c), each a release
# build in its own process, on the hpack-test-case corpus.
#
#   /usr/bin/ruby bench/hpack/run_ab.rb MICA_RUNNER NGHTTP2_RUNNER CORPUS ROUNDS OUT_DIR
#
# Each round runs both runners (the order alternates by round), each with
# 3 warm-up passes and 15 timed passes, and keeps each runner's median
# pass. The ratio nghttp2 / Mica per round gives the speed-up; its 95%
# interval is a bootstrap over rounds (seeded, 10,000 resamples). Both
# runners must report the same field count and field bytes. Writes
# REPORT.md and samples.tsv to OUT_DIR.
require 'fileutils'

mica, nghttp2, corpus, rounds, out = ARGV
abort 'usage: run_ab.rb MICA NGHTTP2 CORPUS ROUNDS OUT_DIR' unless out
rounds = rounds.to_i
FileUtils.mkdir_p(out)
engines = { 'mica' => mica, 'nghttp2' => nghttp2 }
samples = []
work = {}
rounds.times do |round|
  order = round.even? ? %w[mica nghttp2] : %w[nghttp2 mica]
  order.each do |engine|
    lines = IO.popen([engines[engine], corpus, '3', '15'], &:read).lines.map(&:split)
    abort "#{engine} failed" unless $?.success? && lines.size == 15
    times = lines.map { |line| line[1].to_i }.sort
    work[engine] ||= lines.first[2, 2]
    abort "#{engine} decoded different work #{lines.first[2, 2]} vs #{work[engine]}" unless lines.first[2, 2] == work[engine]
    samples << [round, engine, times[times.size / 2]]
  end
end
abort "engines decoded different fields: #{work}" unless work['mica'] == work['nghttp2']

block_bytes = 0
File.open(corpus, 'rb') do |file|
  while (kind = file.read(1))
    case kind
    when 'T' then file.read(4)
    when 'B'
      length = file.read(4).unpack1('N')
      block_bytes += length
      file.read(length)
    end
  end
end

def median(values) = values.sort[values.size / 2]

ratios = (0...rounds).map do |round|
  by_engine = samples.select { |sample| sample[0] == round }.to_h { |sample| [sample[1], sample[2]] }
  by_engine['nghttp2'].to_f / by_engine['mica']
end
random = Random.new(20_261_122)
boot = Array.new(10_000) { median(Array.new(rounds) { ratios[random.rand(rounds)] }) }.sort
low = boot[(0.025 * boot.size).floor]
high = boot[(0.975 * boot.size).floor]
ratio = median(ratios)
phrase = ->(value) { value >= 1 ? format('%.2f× as fast as', value) : format('%.2f× slower than', 1 / value) }
mb_s = ->(engine) { block_bytes / (median(samples.select { |s| s[1] == engine }.map { |s| s[2] }) / 1e9) / 1e6 }
machine = `sysctl -n machdep.cpu.brand_string`.strip
host = `hostname -s`.strip
File.write(File.join(out, 'samples.tsv'), "round\tengine\tmedian_pass_ns\n" + samples.map { |s| s.join("\t") }.join("\n") + "\n")
File.write(File.join(out, 'REPORT.md'), <<~MD)
  # HPACK decode: Mica against nghttp2 1.71.0

  Machine: #{host} (#{machine}), #{`sysctl -n hw.ncpu`.strip} cores. Each engine is a release build in its own
  process; #{rounds} interleaved rounds alternating order; each round keeps each engine's median of 15 timed
  passes after 3 warm-up passes. Corpus: http2jp/hpack-test-case 8a1406e, every story of the 14
  implementation directories (#{work['mica'][0]} fields, #{block_bytes} block bytes), one decoder per story.

  | Engine | Median pass | Block MB/s |
  |---|---|---|
  | Mica | #{format('%.2f', median(samples.select { |s| s[1] == 'mica' }.map { |s| s[2] }) / 1e6)} ms | #{format('%.1f', mb_s.call('mica'))} |
  | nghttp2 1.71.0 | #{format('%.2f', median(samples.select { |s| s[1] == 'nghttp2' }.map { |s| s[2] }) / 1e6)} ms | #{format('%.1f', mb_s.call('nghttp2'))} |

  **Mica decodes #{phrase.call(ratio)} nghttp2** (median of per-round ratios #{format('%.3f', ratio)};
  bootstrap 95% interval #{format('%.3f', low)} to #{format('%.3f', high)}).
MD
puts File.read(File.join(out, 'REPORT.md'))
