# Writes the Markdown and JSON report for a run directory.
#   bench/bin/regex/write_report --run DIR --markdown REPORT.md --json report.json
require "option_parser"
require "./src/regex_bench"

run_directory = File.expand_path("../data/regex/runs/latest", __DIR__)
markdown_path = ""
json_path = ""
title = "Mica::Regex vs PCRE2 benchmark"

OptionParser.parse do |parser|
  parser.banner = "usage: write_report [options]"
  parser.on("--run DIR", "Run directory with results.jsonl and run.json") { |value| run_directory = value }
  parser.on("--markdown PATH", "Markdown report path (default DIR/REPORT.md)") { |value| markdown_path = value }
  parser.on("--json PATH", "JSON report path (default DIR/report.json)") { |value| json_path = value }
  parser.on("--title TEXT", "Report title") { |value| title = value }
end

markdown_path = File.join(run_directory, "REPORT.md") if markdown_path.empty?
json_path = File.join(run_directory, "report.json") if json_path.empty?
RegexBench::WriteTheReport.new(run_directory, File.join(__DIR__, "corpus"), markdown_path, json_path, title).perform
STDERR.puts "wrote #{markdown_path} and #{json_path}"
