# Measures what `Mica::Regex.static` adds to an application's build
# (docs/benchmarks.md, "GC-free study"):
#
# 1. per pattern, the seconds the build-time program takes (run directly,
#    median of three) and the bytes of source it writes;
# 2. a small application holding the Amber corpus patterns as constants,
#    built once with `Mica::Regex.static` and once with
#    `Mica::Regex.compile`, cold (empty cache) and warm, release and
#    debug, the two variants interleaved, three runs each; and the size of
#    each binary.
#
#   /usr/bin/ruby bench/regex/gc_study/build_cost.rb OUT_DIR
require "json"
require "fileutils"

ROOT = File.expand_path("../../..", __dir__)
out_dir = ARGV[0] or abort "usage: build_cost.rb OUT_DIR"
FileUtils.mkdir_p(out_dir)
work = File.join(ROOT, "bench/data/regex/build_cost")
FileUtils.mkdir_p(work)

def now
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

def crystal_literal(text)
  body = text.each_char.map do |char|
    case char
    when "\"" then "\\\""
    when "\\" then "\\\\"
    when "#" then "\\#"
    else char.ord < 0x20 || char.ord == 0x7F ? format("\\u{%X}", char.ord) : char
    end
  end.join
  "\"#{body}\""
end

amber = JSON.parse(File.read(File.join(ROOT, "bench/regex/corpus/amber.json")))["patterns"]

# 1. The build-time program, per pattern.
cache = ENV.fetch("CRYSTAL_CACHE_DIR")
emitter = Dir[File.join(cache, "*emit_static_pattern.cr", "macro_run")].first or
  abort "build something with Mica::Regex.static first, so the cache holds the build-time program"
pairs = amber.map { |entry| [entry["pattern"], entry["case_insensitive"] == true, "amber/#{entry["generator"]}/#{entry["name"]}"] }
generated = File.join(ROOT, "bench/data/regex/static_patterns.cr")
File.read(generated).scan(/table\[\{("(?:[^"\\]|\\.)*"), (true|false)\}\]/) do |literal, insensitive|
  source = literal[1..-2].gsub(/\\u\{([0-9A-F]+)\}|\\(.)/) { Regexp.last_match(1) ? Regexp.last_match(1).to_i(16).chr(Encoding::UTF_8) : Regexp.last_match(2) }
  pairs << [source, insensitive == "true", "rebar-short"]
end
pairs.uniq! { |source, insensitive, _| [source, insensitive] }
rows = pairs.map do |source, insensitive, origin|
  times = 3.times.map do
    started = now
    output = IO.popen([emitter, source, insensitive ? "1" : "0"], &:read)
    [now - started, output]
  end
  output = times.first[1]
  note, code = output.split("%%\n", 2)
  { origin: origin, source: source[0, 80], ignore_case: insensitive,
    seconds: times.map(&:first).sort[1], source_bytes: code.to_s.bytesize,
    static: note.strip.empty?, note: note.strip[0, 160] }
end
File.write(File.join(out_dir, "emitter.jsonl"), rows.map(&:to_json).join("\n") + "\n")

# 2. The application, both ways.
def write_app(path, amber, static)
  File.open(path, "w") do |file|
    file.puts "require \"../../../../src/mica\""
    amber.each_with_index do |entry, index|
      literal = crystal_literal(entry["pattern"])
      insensitive = entry["case_insensitive"] == true
      if static
        file.puts "PATTERN_#{index} = Mica::Regex.static(#{literal}, ignore_case: #{insensitive})"
      else
        options = insensitive ? "Mica::Regex::CompileOptions::IgnoreCase" : "Mica::Regex::CompileOptions::None"
        file.puts "PATTERN_#{index} = Mica::Regex.compile(#{literal}, dialect: :crystal, compile_limits: Mica::Regex::CompileLimits::TRUSTED_PATTERN, options: #{options})"
      end
    end
    file.puts "found = 0"
    amber.size.times do |index|
      search = static ? "PATTERN_#{index}.search(ARGV[0]? || \"\")" : "PATTERN_#{index}.search(ARGV[0]? || \"\", limits: Mica::Regex::SearchLimits::REQUEST)"
      file.puts "found += 1 if #{search}"
    end
    file.puts "puts found"
  end
end

static_app = File.join(work, "app_static.cr")
runtime_app = File.join(work, "app_runtime.cr")
write_app(static_app, amber, true)
write_app(runtime_app, amber, false)

def build(app, release, cache_dir)
  binary = app.sub(/\.cr\z/, release ? "_release" : "_debug")
  args = ["crystal-alpha", "build", app, "-o", binary]
  args << "--release" if release
  started = now
  ok = system({ "CRYSTAL_CACHE_DIR" => cache_dir }, *args, out: File::NULL, err: File::NULL)
  abort "build failed: #{args.join(" ")}" unless ok
  [now - started, File.size(binary)]
end

builds = []
[true, false].each do |release|
  cold_cache = File.join(work, "cache-cold")
  [static_app, runtime_app].each do |app|
    FileUtils.rm_rf(cold_cache)
    seconds, bytes = build(app, release, cold_cache)
    builds << { app: File.basename(app), release: release, cache: "cold", run: 1, seconds: seconds, binary_bytes: bytes }
  end
  warm_cache = File.join(work, "cache-warm")
  3.times do |run|
    [static_app, runtime_app].each do |app|
      seconds, bytes = build(app, release, warm_cache)
      builds << { app: File.basename(app), release: release, cache: "warm", run: run + 1, seconds: seconds, binary_bytes: bytes }
    end
  end
end
File.write(File.join(out_dir, "app_builds.jsonl"), builds.map(&:to_json).join("\n") + "\n")
FileUtils.rm_rf(File.join(work, "cache-cold"))
FileUtils.rm_rf(File.join(work, "cache-warm"))
puts "wrote #{out_dir}/emitter.jsonl (#{rows.size} patterns) and app_builds.jsonl (#{builds.size} builds)"
