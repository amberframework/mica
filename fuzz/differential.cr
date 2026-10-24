# Differential fuzzing: the same seeded cases as spec/mica/fuzz_spec.cr,
# judged by Mica and by stdlib XML (libxml2, strict: NONET without RECOVER).
#
#   crystal-alpha run --release fuzz/differential.cr -- SEED ITERATIONS
#
# libxml2 is an independent oracle, not ground truth: it reports namespace
# errors as non-fatal, so "Mica rejects / libxml2 accepts" is expected for
# Namespaces 1.0 violations. Cases where Mica accepts and libxml2 rejects
# are printed for triage.
require "xml"
require "../src/mica"
require "./mutator"

seed = (ARGV[0]? || "20261024").to_i64
iterations = (ARGV[1]? || "20000").to_i

both_accept = 0
both_reject = 0
mica_only_rejects = Hash(String, Int32).new(0)
mica_only_accepts = [] of {Int32, String}

iterations.times do |iteration|
  bytes = Fuzz.case_bytes(seed, iteration)
  mica_error = nil
  begin
    Mica.parse(bytes)
  rescue error : Mica::Error
    mica_error = error.message.to_s.sub(/ \(line.*\z/, "").gsub(/'[^']*'/, "'…'")
  end
  libxml2_error = nil
  begin
    XML.parse(String.new(bytes), XML::ParserOptions::NONET)
  rescue error : XML::Error
    libxml2_error = error.message.to_s
  end
  if mica_error && libxml2_error
    both_reject += 1
  elsif mica_error
    mica_only_rejects[mica_error] += 1
  elsif libxml2_error
    mica_only_accepts << {iteration, libxml2_error}
  else
    both_accept += 1
  end
end

puts "seed=#{seed} iterations=#{iterations}"
puts "both accept: #{both_accept}"
puts "both reject: #{both_reject}"
puts "Mica rejects, libxml2 accepts: #{mica_only_rejects.values.sum}"
mica_only_rejects.to_a.sort_by { |(_, count)| -count }.first(25).each do |message, count|
  puts "  #{count.to_s.rjust(6)}  #{message}"
end
puts "Mica accepts, libxml2 rejects: #{mica_only_accepts.size}"
mica_only_accepts.group_by(&.[1]).to_a.sort_by { |(_, cases)| -cases.size }.first(25).each do |message, cases|
  puts "  #{cases.size.to_s.rjust(6)}  #{message.strip[0, 120]}  (e.g. iteration #{cases.first[0]})"
end
