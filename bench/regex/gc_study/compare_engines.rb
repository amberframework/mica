# Compares the study's three engines per group from one or more paired
# runs (results.jsonl of run_study.sh): geometric means of the per-case
# ratios, and of the absolute times, for warm search, compile and cold
# first search, plus peak memory. A case counts when all three engines
# report ok with the same count. ALLOC.jsonl (measure_allocations) says
# which patterns the static path holds; "static held" rows keep only those.
#
#   /usr/bin/ruby bench/regex/gc_study/compare_engines.rb ALLOC.jsonl RUN_DIR [RUN_DIR...] > COMPARISON.md
require "json"

alloc_path, *run_dirs = ARGV
abort "usage: compare_engines.rb ALLOC.jsonl RUN_DIR..." if run_dirs.empty?
held = {}
File.readlines(alloc_path).each do |line|
  row = JSON.parse(line)
  held[row["case_id"]] = row["static_status"] == "static"
end

def geomean(values)
  values = values.select { |v| v > 0 }
  return nil if values.empty?
  Math.exp(values.sum { |v| Math.log(v) } / values.size)
end

def ns(seconds)
  return "-" unless seconds
  value = seconds * 1e9
  return "#{value.round(0).to_i} ns" if value < 10_000
  return "#{(value / 1000).round(1)} µs" if value < 10_000_000
  "#{(value / 1e6).round(2)} ms"
end

def ratio(value)
  value ? format("%.3fx", value) : "-"
end
def bytes(value)
  value ? "#{(value / 1048576.0).round(1)} MiB" : "-"
end

METRICS = { "warm" => "warm_search", "compile" => "compile", "cold" => "cold_first_search" }

run_dirs.each do |dir|
  rows = File.readlines(File.join(dir, "results.jsonl")).map { |line| JSON.parse(line) }
  cases = rows.group_by { |row| row["case_id"] }.map do |id, list|
    by = list.to_h { |row| [row["engine"], row] }
    next nil unless %w[pcre2-jit mica mica-static].all? { |e| by[e] && by[e]["status"] == "ok" }
    next nil unless by["mica"]["count"] == by["mica-static"]["count"] && by["mica"]["count"] == by["pcre2-jit"]["count"]
    { id: id, group: by["mica"]["group"], held: held[id], by: by }
  end.compact
  mismatches = rows.group_by { |row| row["case_id"] }.count do |_, list|
    by = list.to_h { |row| [row["engine"], row] }
    by["mica"] && by["mica-static"] && by["mica"]["status"] == "ok" && by["mica-static"]["status"] == "ok" &&
      by["mica"]["count"] != by["mica-static"]["count"]
  end
  puts "## #{File.basename(dir)}"
  puts
  puts "#{cases.size} cases where the three engines agree; #{mismatches} count mismatches between mica and mica-static."
  puts
  sets = []
  cases.group_by { |c| c[:group] }.sort.each { |group, list| sets << [group, list] }
  sets << ["amber (all)", cases.select { |c| c[:group].start_with?("amber/") }]
  sets << ["rebar short (all)", cases.select { |c| c[:group].start_with?("rebar/") }]
  sets << ["amber (static held)", cases.select { |c| c[:group].start_with?("amber/") && c[:held] }]
  sets << ["rebar short (static held)", cases.select { |c| c[:group].start_with?("rebar/") && c[:held] }]
  sets << ["all (static held)", cases.select { |c| c[:held] }]
  METRICS.each do |label, key|
    puts "### #{label} (#{key}), geometric means"
    puts
    puts "| Group | Cases | PCRE2-JIT | Mica runtime | Mica static | static / runtime | static / PCRE2-JIT | runtime / PCRE2-JIT | static faster than runtime |"
    puts "|---|---|---|---|---|---|---|---|---|"
    sets.each do |name, list|
      next if list.empty?
      t = ->(c, e) { c[:by][e][key]["median"] }
      jit = geomean(list.map { |c| t.(c, "pcre2-jit") })
      mica = geomean(list.map { |c| t.(c, "mica") })
      static = geomean(list.map { |c| t.(c, "mica-static") })
      sr = geomean(list.map { |c| t.(c, "mica-static") / t.(c, "mica") if t.(c, "mica") > 0 }.compact)
      sj = geomean(list.map { |c| t.(c, "mica-static") / t.(c, "pcre2-jit") if t.(c, "pcre2-jit") > 0 }.compact)
      mj = geomean(list.map { |c| t.(c, "mica") / t.(c, "pcre2-jit") if t.(c, "pcre2-jit") > 0 }.compact)
      faster = list.count { |c| t.(c, "mica-static") < t.(c, "mica") }
      puts "| #{name} | #{list.size} | #{ns(jit)} | #{ns(mica)} | #{ns(static)} | #{ratio(sr)} | #{ratio(sj)} | #{ratio(mj)} | #{faster} |"
    end
    puts
  end
  puts "### peak memory (peak RSS minus RSS after the haystack was built), medians"
  puts
  puts "| Group | Cases | PCRE2-JIT | Mica runtime | Mica static |"
  puts "|---|---|---|---|---|"
  sets.each do |name, list|
    next if list.empty?
    med = ->(e) { v = list.map { |c| c[:by][e]["peak_rss_bytes"] - c[:by][e]["rss_after_haystack_bytes"] }.sort; v[v.size / 2] }
    abs = ->(e) { v = list.map { |c| c[:by][e]["peak_rss_bytes"] }.sort; v[v.size / 2] }
    puts "| #{name} | #{list.size} | #{(med.("pcre2-jit") / 1024.0).round(0)} KiB (peak #{bytes(abs.("pcre2-jit"))}) | #{(med.("mica") / 1024.0).round(0)} KiB (peak #{bytes(abs.("mica"))}) | #{(med.("mica-static") / 1024.0).round(0)} KiB (peak #{bytes(abs.("mica-static"))}) |"
  end
  puts
end
