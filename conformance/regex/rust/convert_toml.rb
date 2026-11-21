# Fetches the Rust regex test data files named in manifest.json (each
# pinned by sha256), and converts every [[test]] table into
# spec/regex/fixtures/rust_regex_cases.json.
#
#   /usr/bin/ruby conformance/regex/rust/convert_toml.rb
#
# The files use a small part of TOML: [[test]] headers, key = value lines,
# basic, literal and multi-line strings, integers, booleans, arrays (which
# may span lines) and inline tables. This script reads exactly that part
# (Ruby's standard library has no TOML reader) and stops on anything else.
#
# Each case keeps the test's own fields. A haystack with unescape = true is
# unescaped as regex-test does (\xNN bytes, \n, \r, \t, \0, \\ and quotes)
# and stored as hex when the result is not valid UTF-8. Case ids are
# "<file>/<name>". Downloads are cached under tmp/regex-corpora/rust/
# (git-ignored); a sha256 mismatch stops the script.
require "json"
require "digest"
require "fileutils"
require "open3"

ROOT = File.expand_path("../../..", __dir__)
MANIFEST = JSON.parse(File.read(File.join(__dir__, "manifest.json")))
CACHE = File.join(ROOT, "tmp", "regex-corpora", "rust-#{MANIFEST.fetch("commit")[0, 12]}")
OUTPUT = File.join(ROOT, "spec", "regex", "fixtures", "rust_regex_cases.json")

def fetch(file, sha256)
  path = File.join(CACHE, file)
  FileUtils.mkdir_p(File.dirname(path))
  unless File.exist?(path)
    url = MANIFEST.fetch("url_template").sub("{commit}", MANIFEST.fetch("commit")).sub("{file}", file)
    _, status = Open3.capture2("curl", "-sSfL", "-o", path, url)
    abort("download failed: #{url}") unless status.success?
  end
  actual = Digest::SHA256.file(path).hexdigest
  if actual != sha256
    File.delete(path)
    abort("sha256 mismatch for #{file}: expected #{sha256}, got #{actual}")
  end
  path
end

# A reader for the TOML subset the test files use.
class TomlSubset
  def initialize(text, file)
    @text = text
    @file = file
    @pos = 0
  end

  def tables
    list = []
    current = nil
    loop do
      skip_space_and_comments
      break if @pos >= @text.size
      if @text[@pos, 8] == "[[test]]"
        @pos += 8
        current = {}
        list << current
      else
        abort("#{@file}: key outside a [[test]] table at #{@pos}") unless current
        key = read_key
        skip_inline_space
        expect("=")
        skip_inline_space
        current[key] = read_value
      end
    end
    list
  end

  private

  def fail!(message)
    abort("#{@file}: #{message} at byte #{@pos}: #{@text[@pos, 30].inspect}")
  end

  def expect(token)
    fail!("expected #{token}") unless @text[@pos, token.size] == token
    @pos += token.size
  end

  def skip_inline_space
    @pos += 1 while @pos < @text.size && " \t".include?(@text[@pos])
  end

  def skip_space_and_comments
    loop do
      @pos += 1 while @pos < @text.size && " \t\r\n".include?(@text[@pos])
      break unless @text[@pos] == "#"
      @pos += 1 while @pos < @text.size && @text[@pos] != "\n"
    end
  end

  def read_key
    start = @pos
    @pos += 1 while @pos < @text.size && @text[@pos] =~ /[A-Za-z0-9_-]/
    fail!("expected a key") if start == @pos
    @text[start...@pos]
  end

  def read_value
    char = @text[@pos]
    if @text[@pos, 3] == "'''"
      read_multiline_literal
    elsif @text[@pos, 3] == '"""'
      fail!("multi-line basic strings are not used")
    elsif char == "'"
      read_literal
    elsif char == '"'
      read_basic
    elsif char == "["
      read_array
    elsif char == "{"
      read_inline_table
    elsif @text[@pos, 4] == "true"
      @pos += 4
      true
    elsif @text[@pos, 5] == "false"
      @pos += 5
      false
    elsif char =~ /[-0-9]/
      start = @pos
      @pos += 1
      @pos += 1 while @text[@pos] =~ /[0-9_]/
      Integer(@text[start...@pos].delete("_"))
    else
      fail!("unsupported value")
    end
  end

  def read_multiline_literal
    @pos += 3
    @pos += 1 if @text[@pos] == "\n"
    finish = @text.index("'''", @pos) || fail!("unterminated '''")
    # Up to two quotes may sit before the closing delimiter.
    finish += 1 while @text[finish + 3] == "'"
    value = @text[@pos...finish]
    @pos = finish + 3
    value
  end

  def read_literal
    @pos += 1
    finish = @text.index("'", @pos) || fail!("unterminated '")
    value = @text[@pos...finish]
    @pos = finish + 1
    value
  end

  def read_basic
    @pos += 1
    out = +""
    loop do
      char = @text[@pos] || fail!("unterminated string")
      @pos += 1
      break if char == '"'
      if char != "\\"
        out << char
        next
      end
      escape = @text[@pos]
      @pos += 1
      case escape
      when "b" then out << "\b"
      when "t" then out << "\t"
      when "n" then out << "\n"
      when "f" then out << "\f"
      when "r" then out << "\r"
      when "e" then out << "\e"
      when '"' then out << '"'
      when "\\" then out << "\\"
      when "x"
        out << @text[@pos, 2].to_i(16).chr(Encoding::UTF_8)
        @pos += 2
      when "u"
        out << [@text[@pos, 4].to_i(16)].pack("U")
        @pos += 4
      when "U"
        out << [@text[@pos, 8].to_i(16)].pack("U")
        @pos += 8
      else
        fail!("unknown escape \\#{escape}")
      end
    end
    out
  end

  def read_array
    @pos += 1
    list = []
    loop do
      skip_space_and_comments
      if @text[@pos] == "]"
        @pos += 1
        return list
      end
      list << read_value
      skip_space_and_comments
      if @text[@pos] == ","
        @pos += 1
      elsif @text[@pos] != "]"
        fail!("expected , or ]")
      end
    end
  end

  def read_inline_table
    @pos += 1
    table = {}
    loop do
      skip_inline_space
      if @text[@pos] == "}"
        @pos += 1
        return table
      end
      key = read_key
      skip_inline_space
      expect("=")
      skip_inline_space
      table[key] = read_value
      skip_inline_space
      @pos += 1 if @text[@pos] == ","
    end
  end
end

# regex-test's unescape (bstr's unescape_bytes): \xNN is one byte, \n \r
# \t \0 \\ \' \" their usual bytes; any other backslash stays as written.
def unescape(text)
  bytes = text.b
  out = "".b
  index = 0
  while index < bytes.bytesize
    char = bytes[index]
    if char != "\\" || index + 1 >= bytes.bytesize
      out << char
      index += 1
      next
    end
    escape = bytes[index + 1]
    case escape
    when "x"
      hex = bytes[index + 2, 2]
      if hex =~ /\A[0-9A-Fa-f]{2}\z/
        out << hex.to_i(16).chr
        index += 4
      else
        out << "\\x"
        index += 2
      end
    when "n" then out << "\n"; index += 2
    when "r" then out << "\r"; index += 2
    when "t" then out << "\t"; index += 2
    when "0" then out << "\0"; index += 2
    when "\\", "'", '"' then out << escape; index += 2
    else
      out << "\\"
      index += 1
    end
  end
  out
end

def put_bytes(record, key, bytes)
  text = bytes.dup.force_encoding("UTF-8")
  if text.valid_encoding?
    record[key] = text
  else
    record["#{key}_hex"] = bytes.unpack1("H*")
  end
end

# Brings the matches to one shape: a list of matches, each a list of spans
# ([begin, end], or nil for a group that did not take part). A test lists
# either spans alone (group 0) or every group (with [] for a group that did
# not take part); regex sets list {id, span} or {id, spans} tables. Returns the matches
# and whether every group is listed.
def normalize_matches(list)
  captures_listed = false
  normalized = list.map do |entry|
    if entry.is_a?(Hash) && entry.key?("span")
      [entry.fetch("span")]
    elsif entry.is_a?(Hash)
      captures_listed = true
      entry.fetch("spans").map { |span| span.empty? ? nil : span }
    elsif entry.empty? || entry.first.is_a?(Integer)
      [entry]
    else
      captures_listed = true
      entry.map { |span| span.empty? ? nil : span }
    end
  end
  [normalized, captures_listed]
end

cases = []
MANIFEST.fetch("files").each do |file, sha256|
  path = fetch(file, sha256)
  TomlSubset.new(File.read(path, encoding: "UTF-8"), file).tables.each do |table|
    name = table.fetch("name")
    record = {"id" => "#{file}/#{name}"}
    regex = table.fetch("regex")
    if regex.is_a?(Array)
      record["regex_set"] = regex
    else
      record["pattern"] = regex
    end
    haystack = table.fetch("haystack")
    haystack = unescape(haystack) if table["unescape"]
    put_bytes(record, "haystack", haystack.b)
    record["matches"], record["captures_listed"] = normalize_matches(table.fetch("matches"))
    if (bounds = table["bounds"])
      record["bounds"] = bounds.is_a?(Hash) ? [bounds.fetch("start"), bounds.fetch("end")] : bounds
    end
    %w[match-limit anchored case-insensitive compiles unicode utf8 match-kind search-kind line-terminator].each do |key|
      record[key] = table[key] if table.key?(key)
    end
    cases << record
  end
end

ids = cases.map { |record| record["id"] }
abort("duplicate case ids") unless ids.uniq.size == ids.size
FileUtils.mkdir_p(File.dirname(OUTPUT))
File.write(OUTPUT, JSON.pretty_generate({"commit" => MANIFEST.fetch("commit"), "case_count" => cases.size,
                                         "cases" => cases}) + "\n")
puts "#{cases.size} cases written to #{OUTPUT.sub(ROOT + "/", "")}"
