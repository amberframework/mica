# Summarizes measure_allocations output per benchmark group: allocations
# (count and bytes) per compile, per first search and per warm search, the
# collector's share of warm time, and the table-width distribution.
#
#   /usr/bin/ruby bench/regex/gc_study/summarize_allocations.rb ALLOC.jsonl > SUMMARY.md
require "json"

rows = File.readlines(ARGV[0] || abort("usage: summarize_allocations.rb ALLOC.jsonl")).map { |line| JSON.parse(line) }
ok = rows.select { |row| row["status"] == "ok" }

def median(list)
  return 0 if list.empty?
  sorted = list.sort
  sorted[sorted.size / 2]
end

def fmt(value, digits = 1)
  value.is_a?(Float) ? value.round(digits).to_s : value.to_s
end

puts "## Allocations on the runtime engine, per group (release build)"
puts
puts "Cases: #{rows.size} (#{ok.size} ok). Amber haystacks up to 1 MiB. Adapting searches = the 2nd and 3rd workload runs, while the engine builds its plan, caches and filters. Warm = after 200 more runs (or 0.2 s), allocations over 0.05 s of runs / the finds they made."
puts
puts "| Group | Cases | Compile allocs (median) | Compile bytes (median) | First search allocs (median) | First search bytes (median) | Adapting searches: allocs per search (all finds) | Warm allocs per search (all finds) | Warm bytes per search (all finds) | Warm allocs per search (median case) | Cases with 0 warm allocs | GC collections in warm runs | Warm time with GC on (s) | with GC off (s) | GC share |"
puts "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"
groups = ok.group_by { |row| row["group"] }.sort_by { |name, _| name }
totals = ok
(groups + [["all", totals]]).each do |name, list|
  finds = list.sum { |row| row["warm_finds"] }
  warm_allocs = list.sum { |row| row["warm_allocations"] }
  warm_bytes = list.sum { |row| row["warm_bytes"] }
  zero = list.count { |row| row["warm_allocations"] == 0 }
  on = list.sum { |row| row["gc_on_seconds"] }
  off = list.sum { |row| row["gc_off_seconds"] }
  collections = list.sum { |row| row["gc_collections"] }
  share = on > 0 ? (on - off) / on * 100 : 0
  puts "| #{name} | #{list.size} | #{median(list.map { |r| r["compile_allocations"] })} | #{median(list.map { |r| r["compile_bytes"] })} | " \
       "#{median(list.map { |r| r["first_search_allocations"] })} | #{median(list.map { |r| r["first_search_bytes"] })} | " \
       "#{(early = list.sum { |r| r["early_finds"].to_i }) > 0 ? fmt(list.sum { |r| r["early_allocations"].to_i }.to_f / early, 2) : "-"} | " \
       "#{finds > 0 ? fmt(warm_allocs.to_f / finds, 2) : "-"} | #{finds > 0 ? fmt(warm_bytes.to_f / finds, 1) : "-"} | #{fmt(median(list.select { |r| r["warm_finds"] > 0 }.map { |r| r["warm_allocations"].to_f / r["warm_finds"] }), 2)} | #{zero} | " \
       "#{collections} | #{fmt(on, 3)} | #{fmt(off, 3)} | #{fmt(share, 1)}% |"
end
puts
puts "## Table shapes across the corpus (distinct patterns)"
puts
distinct = ok.uniq { |row| [row["case_id"].split("@").first, row["nfa_states"], row["capture_count"]] }
by_pattern = ok.group_by { |row| row["case_id"].sub(/@.*/, "") }.map { |_, list| list.first }
def bucket(value)
  return "<= 255 (UInt8)" if value <= 255
  return "<= 65,535 (UInt16)" if value <= 65_535
  "> 65,535 (UInt32)"
end
puts "Distinct patterns: #{by_pattern.size}."
puts
puts "| Quantity | <= 255 (UInt8) | <= 65,535 (UInt16) | > 65,535 (UInt32) | median | p90 | max |"
puts "|---|---|---|---|---|---|---|"
quantities = {
  "NFA states" => by_pattern.map { |r| r["nfa_states"] },
  "byte classes" => by_pattern.map { |r| r["byte_classes"] },
  "capture groups" => by_pattern.map { |r| r["capture_count"] },
  "capture slots" => by_pattern.map { |r| r["slot_count"] },
}
static = by_pattern.select { |r| r["static_status"] == "static" }
quantities["forward DFA states (static)"] = static.map { |r| r["forward"]["states"] }
quantities["reverse DFA states (static)"] = static.map { |r| r["reverse"]["states"] }
quantities["forward premultiplied entry (static)"] = static.map { |r| (r["forward"]["states"] - 1) * r["forward"]["stride"] }
quantities["reverse premultiplied entry (static)"] = static.map { |r| (r["reverse"]["states"] - 1) * r["reverse"]["stride"] }
quantities.each do |name, values|
  sorted = values.sort
  counts = values.group_by { |v| bucket(v) }.transform_values(&:size)
  p90 = sorted[(sorted.size * 0.9).floor.clamp(0, sorted.size - 1)]
  puts "| #{name} | #{counts["<= 255 (UInt8)"] || 0} | #{counts["<= 65,535 (UInt16)"] || 0} | #{counts["> 65,535 (UInt32)"] || 0} | #{median(values)} | #{p90} | #{sorted.last} |"
end
puts
puts "Static build: #{static.size} of #{by_pattern.size} distinct patterns fit (#{by_pattern.size - static.size} fall back)."
reasons = by_pattern.reject { |r| r["static_status"] == "static" }.map { |r| r["static_reason"].sub(/\d[\d,]*/, "N").sub(/\d+/, "N").split(":").first }
reasons.group_by { |x| x }.map { |k, v| [k, v.size] }.sort_by { |_, n| -n }.each { |reason, n| puts "- #{n}: #{reason}" }
puts
tables = static.map { |r| r["static_table_bytes"] }.sort
puts "Static table bytes (classes + forward + reverse): median #{median(tables)}, p90 #{tables[(tables.size * 0.9).floor]}, max #{tables.last}."
scratch = static.map { |r| r["static_scratch_bytes"] }.reject(&:zero?).sort
puts "Capture-pass stack scratch (patterns with groups): #{scratch.size} patterns, median #{median(scratch)} bytes, max #{scratch.last} bytes."
widths = static.map { |r| [r["forward"]["entry_bytes"], r["reverse"]["entry_bytes"]].max }.group_by { |x| x }.map { |k, v| [k, v.size] }.sort
puts "Widest table entry per static pattern: #{widths.map { |w, n| "#{n} at #{w} byte#{w > 1 ? "s" : ""}" }.join(", ")}."
ids = static.map { |r| [r["forward"]["state_id_bytes"], r["reverse"]["state_id_bytes"]].max }.group_by { |x| x }.map { |k, v| [k, v.size] }.sort
puts "State-id width (unpremultiplied) per static pattern: #{ids.map { |w, n| "#{n} at #{w} byte#{w > 1 ? "s" : ""}" }.join(", ")}."
build = static.map { |r| r["static_build_seconds"] * 1000 }.sort
puts "Table build time in this (release) tool: median #{fmt(median(build), 2)} ms, p90 #{fmt(build[(build.size * 0.9).floor], 2)} ms, max #{fmt(build.last, 1)} ms."
