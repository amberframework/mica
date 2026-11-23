# Writes a Markdown speed table from run_ab.rb results: per case MB/s of
# each engine and Mica's speed as a multiple of the reference, with a
# paired bootstrap 95% interval over rounds, and the geometric mean.
#
#   /usr/bin/ruby bench/brotli/report.rb RESULTS.json [MORE.json ...]
require "json"

def geo(values)
  Math.exp(values.sum { |v| Math.log(v) } / values.size)
end

def say(ratio)
  ratio >= 1 ? "#{format("%.2f", ratio)}× as fast" : "#{format("%.2f", 1 / ratio)}× slower"
end

ARGV.each do |path|
  data = JSON.parse(File.read(path))
  raw_size = data["cases"].to_h { |n, q, raw, _| ["#{n}.q#{q}", raw] }
  random = Random.new(20261122)
  rows = []
  per_case = {}
  data["samples"].each do |key, engines|
    ratios = engines["ref"].zip(engines["mica"]).map { |r, m| r.to_f / m }
    per_case[key] = ratios
    boot = Array.new(2000) { geo(Array.new(ratios.size) { ratios[random.rand(ratios.size)] }) }.sort
    mica_ms = engines["mica"].sort[engines["mica"].size / 2]
    ref_ms = engines["ref"].sort[engines["ref"].size / 2]
    rows << [key, raw_size[key], raw_size[key] * 1000.0 / ref_ms, raw_size[key] * 1000.0 / mica_ms, geo(ratios), boot[50], boot[1949]]
  end
  rounds = per_case.values.first.size
  boot = Array.new(2000) do
    picks = Array.new(rounds) { random.rand(rounds) }
    geo(per_case.values.map { |r| geo(picks.map { |i| r[i] }) })
  end.sort
  overall = geo(per_case.values.map { |r| geo(r) })
  puts "### #{data["mode"]} decode, #{data["host"]} (#{data["cpu"]}), #{rounds} rounds"
  puts
  puts "Geometric mean over #{rows.size} cases: Mica is **#{say(overall)}** than libbrotlidec 1.2.1 (95% interval #{format("%.3f", boot[50])} to #{format("%.3f", boot[1949])}× its speed)."
  puts
  puts "| case | bytes | libbrotlidec MB/s | Mica MB/s | Mica vs reference (95% interval) |"
  puts "|---|---|---|---|---|"
  rows.sort_by { |r| r[4] }.each do |key, raw, ref, mica, ratio, low, high|
    puts "| #{key} | #{raw} | #{format("%.1f", ref)} | #{format("%.1f", mica)} | #{say(ratio)} (#{format("%.3f", low)}–#{format("%.3f", high)}) |"
  end
  puts
end
