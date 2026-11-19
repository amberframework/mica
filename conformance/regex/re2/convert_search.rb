# Fetches the RE2 search corpus (re2-search.txt) named in manifest.json,
# checks its sha256, and converts it into
# spec/regex/fixtures/re2_search_cases.json: one case per regexp, haystack
# and result column.
#
#   /usr/bin/ruby conformance/regex/re2/convert_search.rb
#
# The file is a sequence of stanzas: "strings" and Go-quoted haystacks,
# "regexps" and Go-quoted patterns, each pattern followed by one result line
# per haystack. A result line has four semicolon-separated columns, as Go's
# regexp/exec_test.go reads them: full match (the pattern wrapped in
# \A(?:...)\z), partial match (unanchored search), and the same two under
# leftmost-longest semantics. Each column is "-" (no match) or
# space-separated "begin-end" byte pairs for group 0, 1, ... with "-" for a
# group that did not take part.
#
# Case ids are "re2-search.txt:<result line>:<column>". The download is
# cached under tmp/regex-corpora/ (git-ignored); a sha256 mismatch stops the
# script before anything is read.
require "json"
require "digest"
require "fileutils"
require "open3"

ROOT = File.expand_path("../../..", __dir__)
MANIFEST = JSON.parse(File.read(File.join(__dir__, "manifest.json")))
CACHE = File.join(ROOT, "tmp", "regex-corpora")
OUTPUT = File.join(ROOT, "spec", "regex", "fixtures", "re2_search_cases.json")
COLUMNS = %w[full partial full-longest partial-longest].freeze

def fetch_corpus
  FileUtils.mkdir_p(CACHE)
  path = File.join(CACHE, "re2-search-#{MANIFEST.fetch("commit")[0, 12]}.txt")
  unless File.exist?(path)
    _, status = Open3.capture2("curl", "-sSfL", "-o", path, MANIFEST.fetch("url"))
    abort("download failed: #{MANIFEST.fetch("url")}") unless status.success?
  end
  actual = Digest::SHA256.file(path).hexdigest
  if actual != MANIFEST.fetch("sha256")
    File.delete(path)
    abort("sha256 mismatch for #{path}: expected #{MANIFEST.fetch("sha256")}, got #{actual}")
  end
  path
end

# Unquotes a Go double-quoted string literal (strconv.Unquote) into bytes.
def go_unquote(literal)
  abort("not a Go string literal: #{literal}") unless literal.start_with?('"') && literal.end_with?('"')
  body = literal[1...-1].b
  out = "".b
  index = 0
  while index < body.bytesize
    char = body[index]
    if char != "\\"
      out << char
      index += 1
      next
    end
    escape = body[index + 1]
    index += 2
    case escape
    when "a" then out << "\a"
    when "b" then out << "\b"
    when "f" then out << "\f"
    when "n" then out << "\n"
    when "r" then out << "\r"
    when "t" then out << "\t"
    when "v" then out << "\v"
    when "\\", "\"", "'" then out << escape
    when "x"
      out << body[index, 2].to_i(16).chr
      index += 2
    when "u"
      out << [body[index, 4].to_i(16)].pack("U").b
      index += 4
    when "U"
      out << [body[index, 8].to_i(16)].pack("U").b
      index += 8
    when "0".."7"
      out << body[index - 1, 3].to_i(8).chr
      index += 2
    else
      abort("unknown Go escape \\#{escape} in #{literal}")
    end
  end
  out
end

# Stores *bytes* under *key*, or as hex under "<key>_hex" when they are not
# valid UTF-8 (JSON strings must be).
def put_bytes(record, key, bytes)
  text = bytes.dup.force_encoding("UTF-8")
  if text.valid_encoding?
    record[key] = text
  else
    record["#{key}_hex"] = bytes.unpack1("H*")
  end
end

def parse_result(column)
  return nil if column == "-"
  column.split(" ").map do |pair|
    next nil if pair == "-"
    first, last = pair.split("-")
    [Integer(first), Integer(last)]
  end
end

def convert(path)
  cases = []
  strings = []
  in_strings = false
  pattern = nil
  remaining = []
  File.foreach(path).with_index(1) do |raw, line_number|
    line = raw.chomp
    next if line.empty? || line.start_with?("#") || ("A".."Z").cover?(line[0])
    if line == "strings"
      strings = []
      in_strings = true
    elsif line == "regexps"
      in_strings = false
    elsif line.start_with?('"')
      value = go_unquote(line)
      if in_strings
        strings << value
      else
        abort("out of sync at line #{line_number}") unless remaining.empty?
        pattern = value
        remaining = strings.dup
      end
    else
      haystack = remaining.shift || abort("no haystack left at line #{line_number}")
      columns = line.split(";")
      abort("expected 4 columns at line #{line_number}") unless columns.size == 4
      columns.each_with_index do |column, index|
        record = {"id" => "re2-search.txt:#{line_number}:#{COLUMNS[index]}", "mode" => COLUMNS[index]}
        put_bytes(record, "pattern", pattern)
        put_bytes(record, "haystack", haystack)
        record["expected"] = parse_result(column)
        cases << record
      end
    end
  end
  cases
end

cases = convert(fetch_corpus)
FileUtils.mkdir_p(File.dirname(OUTPUT))
File.write(OUTPUT, JSON.pretty_generate({"source" => MANIFEST.fetch("path"), "commit" => MANIFEST.fetch("commit"),
                                         "case_count" => cases.size, "cases" => cases}) + "\n")
puts "#{cases.size} cases written to #{OUTPUT.sub(ROOT + "/", "")}"
