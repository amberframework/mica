# Writes Markdown size and speed tables from encode_ab.rb results, one per
# quality: per case the compressed sizes (Mica's as +N% / -N% of the
# reference), MB/s of each engine, Mica's speed as a multiple of the
# reference with a paired bootstrap 95% interval over rounds, and the
# geometric means.
#
#   /usr/bin/ruby bench/brotli/encode_report.rb RESULTS.json
require "json"

def geo(values)
  Math.exp(values.sum { |v| Math.log(v) } / values.size)
end

# "1.20× as fast" or "1.20× slower"; with *compared*, the comparison word
# the sentence needs ("as fast as", "slower than").
def say(ratio, compared = false)
  if ratio >= 1
    "#{format("%.2f", ratio)}× as fast#{compared ? " as" : ""}"
  else
    "#{format("%.2f", 1 / ratio)}× slower#{compared ? " than" : ""}"
  end
end

def percent(ratio)
  format("%+.1f%%", (ratio - 1) * 100)
end

data = JSON.parse(File.read(ARGV.fetch(0)))
raw_size = data["cases"].to_h { |n, q, raw, _| ["#{n}.q#{q}", raw] }
random = Random.new(20261122)
data["cases"].map { |c| c[1] }.uniq.each do |quality|
  keys = data["samples"].keys.select { |key| key.end_with?(".q#{quality}") }
  rounds = data["samples"][keys.first]["mica"].size
  speed = keys.to_h { |key| [key, data["samples"][key]["ref"].zip(data["samples"][key]["mica"]).map { |r, m| r.to_f / m }] }
  size = keys.to_h { |key| [key, data["sizes"][key]["mica"].to_f / data["sizes"][key]["ref"]] }
  boot = Array.new(2000) do
    picks = Array.new(rounds) { random.rand(rounds) }
    geo(speed.values.map { |r| geo(picks.map { |i| r[i] }) })
  end.sort
  overall = geo(speed.values.map { |r| geo(r) })
  total_mica = keys.sum { |key| data["sizes"][key]["mica"] }
  total_ref = keys.sum { |key| data["sizes"][key]["ref"] }
  puts "### Quality #{quality} encode, #{data["host"]} (#{data["cpu"]}), #{rounds} rounds, window 22"
  puts
  puts "- Speed, geometric mean over #{keys.size} cases: Mica is **#{say(overall, true)}** libbrotlienc 1.2.1 (95% interval #{format("%.3f", boot[50])} to #{format("%.3f", boot[1949])}× its speed)."
  puts "- Size: geometric mean **#{percent(geo(size.values))}**; corpus total #{total_mica} bytes against #{total_ref} (**#{percent(total_mica.to_f / total_ref)}**)."
  puts
  puts "| case | bytes | libbrotlienc size | Mica size | size | libbrotlienc MB/s | Mica MB/s | speed (95% interval) |"
  puts "|---|---|---|---|---|---|---|---|"
  keys.sort_by { |key| -size[key] }.each do |key|
    ratios = speed[key]
    case_boot = Array.new(2000) { geo(Array.new(ratios.size) { ratios[random.rand(ratios.size)] }) }.sort
    mica_ns = data["samples"][key]["mica"].sort[rounds / 2]
    ref_ns = data["samples"][key]["ref"].sort[rounds / 2]
    puts "| #{key} | #{raw_size[key]} | #{data["sizes"][key]["ref"]} | #{data["sizes"][key]["mica"]} | #{percent(size[key])} | " \
         "#{format("%.1f", raw_size[key] * 1000.0 / ref_ns)} | #{format("%.1f", raw_size[key] * 1000.0 / mica_ns)} | " \
         "#{say(geo(ratios))} (#{format("%.3f", case_boot[50])}–#{format("%.3f", case_boot[1949])}) |"
  end
  puts
end
