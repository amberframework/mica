# Prints the patterns of the static differential as JSON lines
# ({"source", "ignore_case", "origin"}): the Amber corpus patterns, then
# *count* patterns of the engine differential's generator (fuzz/
# regex_engine_differential.cr) from *seed*, the ones the runtime compiler
# accepts.
#
#   crystal-alpha run bench/regex/gc_study/list_differential_patterns.cr -- SEED COUNT
require "json"
require "../../../fuzz/regex_engine_differential"

seed = (ARGV[0]? || "20261119").to_i64
count = (ARGV[1]? || "300").to_i
amber = JSON.parse(File.read(File.join(__DIR__, "../corpus/amber.json")))
amber["patterns"].as_a.each do |entry|
  {source: entry["pattern"].as_s, ignore_case: entry["case_insensitive"]?.try(&.as_bool) || false,
   origin: "amber/#{entry["generator"]}/#{entry["name"]}"}.to_json(STDOUT)
  puts
end
accepted = 0
index = 0
while accepted < count
  random = Random::PCG32.new(seed.to_u64, index.to_u64)
  source = EngineDifferential.pattern(random)
  index += 1
  begin
    Mica::Regex::Expression.new(source, compile_limits: EngineDifferential::COMPILE_LIMITS)
  rescue Mica::Regex::SyntaxError | Mica::Regex::CompileLimitError
    next
  end
  accepted += 1
  {source: source, ignore_case: false, origin: "fuzz/#{seed}:#{index - 1}"}.to_json(STDOUT)
  puts
end
