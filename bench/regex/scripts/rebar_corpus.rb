#!/usr/bin/ruby
# frozen_string_literal: true

# Fetches the rebar benchmark corpus at the commit pinned in
# bench/regex/corpus/rebar_source.json, verifies the tarball against the
# recorded sha256 (a mismatch deletes the download and exits non-zero), and
# converts rebar's TOML benchmark definitions into rebar.json beside the
# extracted files (bench/data/regex/rebar-<commit>/rebar.json, git-ignored)
# for the Crystal harness. The JSON is generated rather than committed: it is
# a pure function of the verified tarball, and rebar's fixtures include
# credential-shaped test strings that do not belong in this repository.
#
#   /usr/bin/ruby bench/regex/scripts/rebar_corpus.rb fetch    # download, verify, extract
#   /usr/bin/ruby bench/regex/scripts/rebar_corpus.rb convert  # TOML -> rebar.json
#   /usr/bin/ruby bench/regex/scripts/rebar_corpus.rb          # both
#
# Only the Ruby standard library is used (system /usr/bin/ruby, 2.6+). rebar's
# definitions use a small part of TOML (tables of [[bench]], strings in all
# four quoting styles, integers with underscores, booleans, arrays and inline
# tables), and TomlSubset below parses exactly that part. Anything else is a
# parse error, so a future rebar format change fails loudly here.

require 'json'
require 'digest'
require 'fileutils'
require 'net/http'
require 'uri'

REGEX_BENCH_DIR = File.expand_path('..', __dir__)
SOURCE_PATH = File.join(REGEX_BENCH_DIR, 'corpus', 'rebar_source.json')
DATA_DIR = File.expand_path('../data/regex', REGEX_BENCH_DIR)

# The engine whose expected count the harness verifies against. Crystal's
# stdlib Regex is PCRE2 with JIT, so a benchmark is eligible when rebar
# lists pcre2/jit for it.
BASELINE_ENGINE = 'pcre2/jit'
SUPPORTED_MODELS = %w[compile count count-spans count-captures grep grep-captures].freeze

class TomlSubset
  class ParseError < StandardError; end

  def initialize(text, origin)
    @text = text
    @origin = origin
    @pos = 0
  end

  # Returns { 'top' => {...}, 'bench' => [{...}, ...] }.
  def parse
    top = {}
    benches = []
    current = top
    loop do
      skip_blank_lines_and_comments
      break if @pos >= @text.size

      if @text[@pos, 9] == '[[bench]]'
        @pos += 9
        current = {}
        benches << current
        expect_line_end
      elsif @text[@pos] == '['
        error('only [[bench]] tables are supported')
      else
        key = parse_key
        skip_inline_space
        expect('=')
        skip_inline_space
        current[key] = parse_value
        expect_line_end
      end
    end
    { 'top' => top, 'bench' => benches }
  end

  private

  def error(message)
    line = @text[0, @pos].count("\n") + 1
    raise ParseError, "#{@origin}:#{line}: #{message}"
  end

  def skip_inline_space
    @pos += 1 while @pos < @text.size && [' ', "\t"].include?(@text[@pos])
  end

  def skip_comment
    return unless @text[@pos] == '#'

    @pos += 1 while @pos < @text.size && @text[@pos] != "\n"
  end

  def skip_blank_lines_and_comments
    loop do
      skip_inline_space
      skip_comment
      if @text[@pos] == "\n" || @text[@pos] == "\r"
        @pos += 1
      else
        break
      end
    end
  end

  def expect(token)
    error("expected #{token.inspect}") unless @text[@pos, token.size] == token
    @pos += token.size
  end

  def expect_line_end
    skip_inline_space
    skip_comment
    return if @pos >= @text.size

    @pos += 1 if @text[@pos] == "\r"
    expect("\n")
  end

  def parse_key
    start = @pos
    @pos += 1 while @pos < @text.size && @text[@pos] =~ /[A-Za-z0-9_-]/
    error('expected a bare key') if start == @pos
    @text[start...@pos]
  end

  def parse_value
    if @text[@pos, 3] == "'''"
      parse_multiline_literal
    elsif @text[@pos, 3] == '"""'
      parse_multiline_basic
    elsif @text[@pos] == "'"
      parse_literal
    elsif @text[@pos] == '"'
      parse_basic
    elsif @text[@pos] == '['
      parse_array
    elsif @text[@pos] == '{'
      parse_inline_table
    elsif @text[@pos, 4] == 'true'
      @pos += 4
      true
    elsif @text[@pos, 5] == 'false'
      @pos += 5
      false
    elsif @text[@pos] =~ /[-+0-9]/
      parse_integer
    else
      error('unsupported value')
    end
  end

  def parse_integer
    start = @pos
    @pos += 1 if @text[@pos] =~ /[-+]/
    @pos += 1 while @pos < @text.size && @text[@pos] =~ /[0-9_]/
    literal = @text[start...@pos]
    error("bad integer #{literal.inspect}") unless literal =~ /\A[-+]?[0-9](_?[0-9])*\z/
    Integer(literal.delete('_'), 10)
  end

  def parse_literal
    @pos += 1
    finish = @text.index("'", @pos) || error('unterminated literal string')
    value = @text[@pos...finish]
    error('newline in literal string') if value.include?("\n")
    @pos = finish + 1
    value
  end

  def parse_multiline_literal
    @pos += 3
    @pos += 1 if @text[@pos] == "\n"
    finish = @text.index("'''", @pos) || error('unterminated multi-line literal string')
    value = @text[@pos...finish]
    @pos = finish + 3
    value
  end

  def parse_basic
    @pos += 1
    out = +''
    loop do
      error('unterminated basic string') if @pos >= @text.size
      char = @text[@pos]
      if char == '"'
        @pos += 1
        return out
      elsif char == "\n"
        error('newline in basic string')
      elsif char == '\\'
        out << parse_escape
      else
        out << char
        @pos += 1
      end
    end
  end

  def parse_multiline_basic
    @pos += 3
    @pos += 1 if @text[@pos] == "\n"
    out = +''
    loop do
      error('unterminated multi-line basic string') if @pos >= @text.size
      if @text[@pos, 3] == '"""'
        @pos += 3
        return out
      elsif @text[@pos] == '\\' && @text[@pos + 1] =~ /[ \t\r\n]/
        # A line-ending backslash trims the newline and following whitespace.
        @pos += 1
        @pos += 1 while @pos < @text.size && @text[@pos] =~ /[ \t\r\n]/
      elsif @text[@pos] == '\\'
        out << parse_escape
      else
        out << @text[@pos]
        @pos += 1
      end
    end
  end

  def parse_escape
    @pos += 1
    char = @text[@pos]
    @pos += 1
    case char
    when 'n' then "\n"
    when 't' then "\t"
    when 'r' then "\r"
    when 'b' then "\b"
    when 'f' then "\f"
    when '"' then '"'
    when '\\' then '\\'
    when 'u', 'U'
      width = char == 'u' ? 4 : 8
      hex = @text[@pos, width]
      error("bad unicode escape #{hex.inspect}") unless hex =~ /\A[0-9A-Fa-f]{#{width}}\z/
      @pos += width
      [hex.to_i(16)].pack('U')
    else
      error("unsupported escape \\#{char}")
    end
  end

  def skip_array_space
    loop do
      skip_inline_space
      skip_comment
      if @text[@pos] == "\n" || @text[@pos] == "\r"
        @pos += 1
      else
        break
      end
    end
  end

  def parse_array
    @pos += 1
    values = []
    loop do
      skip_array_space
      if @text[@pos] == ']'
        @pos += 1
        return values
      end
      values << parse_value
      skip_array_space
      if @text[@pos] == ','
        @pos += 1
      elsif @text[@pos] != ']'
        error('expected , or ] in array')
      end
    end
  end

  def parse_inline_table
    @pos += 1
    table = {}
    loop do
      skip_inline_space
      if @text[@pos] == '}'
        @pos += 1
        return table
      end
      key = parse_key
      skip_inline_space
      expect('=')
      skip_inline_space
      table[key] = parse_value
      skip_inline_space
      if @text[@pos] == ','
        @pos += 1
      elsif @text[@pos] != '}'
        error('expected , or } in inline table')
      end
    end
  end
end

def load_source
  JSON.parse(File.read(SOURCE_PATH))
end

def extract_dir(source)
  File.join(DATA_DIR, "rebar-#{source.fetch('commit')}")
end

def fetch(source)
  target = extract_dir(source)
  marker = File.join(target, '.verified-sha256')
  if File.exist?(marker) && File.read(marker).strip == source.fetch('tarball_sha256')
    puts "rebar #{source.fetch('commit')} already fetched and verified at #{target}"
    return
  end

  download_dir = File.join(DATA_DIR, "download-#{source.fetch('commit')}")
  FileUtils.rm_rf(download_dir)
  FileUtils.mkdir_p(download_dir)
  tarball = File.join(download_dir, 'rebar.tar.gz')
  download(source.fetch('tarball_url'), tarball)

  actual = Digest::SHA256.file(tarball).hexdigest
  unless actual == source.fetch('tarball_sha256')
    FileUtils.rm_rf(download_dir)
    abort "rebar tarball sha256 mismatch: expected #{source.fetch('tarball_sha256')}, got #{actual}; download deleted"
  end
  puts "rebar tarball sha256 verified: #{actual}"

  # The archive is untrusted data: it is extracted into its own new, empty
  # directory and only the benchmarks/ tree is kept. Nothing in it is run.
  FileUtils.rm_rf(target)
  FileUtils.mkdir_p(target)
  prefix = "rebar-#{source.fetch('commit')}/benchmarks"
  ok = system('tar', '-xzf', tarball, '-C', target, '--strip-components=2', prefix)
  abort 'tar failed to extract the rebar benchmarks directory' unless ok
  File.write(marker, "#{actual}\n")
  FileUtils.rm_rf(download_dir)
  puts "rebar benchmarks extracted to #{target}"
end

def download(url, destination, redirects_left = 3)
  uri = URI(url)
  Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
    request = Net::HTTP::Get.new(uri)
    request['User-Agent'] = 'mica-regex-bench/1.0'
    http.request(request) do |response|
      case response
      when Net::HTTPSuccess
        File.open(destination, 'wb') { |file| response.read_body { |chunk| file.write(chunk) } }
      when Net::HTTPRedirection
        abort "too many redirects fetching #{url}" if redirects_left.zero?
        return download(response['location'], destination, redirects_left - 1)
      else
        abort "fetching #{url} failed: HTTP #{response.code}"
      end
    end
  end
end

# rebar's count can be one integer or a list of {engine = <regex>, count}
# entries matched in order against the engine name.
def expected_count_for(count, engine)
  return count if count.is_a?(Integer)

  count.each do |entry|
    return entry.fetch('count') if engine =~ /\A(?:#{entry.fetch('engine')})\z/
  end
  nil
end

def resolve_patterns(regex, benchmarks_dir)
  return [regex] if regex.is_a?(String)
  return regex if regex.is_a?(Array)

  patterns = if regex.key?('path')
               text = File.read(File.join(benchmarks_dir, 'regexes', regex.fetch('path')), encoding: 'UTF-8')
               case regex['per-line']
               when nil then [text.strip]
               when 'alternate' then [text.lines.map(&:chomp).reject(&:empty?).map { |line| literal?(regex) ? escape(line) : line }.join('|')]
               when 'pattern' then text.lines.map(&:chomp).reject(&:empty?)
               else raise "unknown per-line mode #{regex['per-line']}"
               end
             else
               Array(regex.fetch('patterns'))
             end
  # 'alternate' already escaped each line; escape the rest here.
  patterns = patterns.map { |pattern| escape(pattern) } if literal?(regex) && regex['per-line'] != 'alternate'
  patterns.map { |pattern| "#{regex['prepend']}#{pattern}#{regex['append']}" }
end

def literal?(regex)
  regex.is_a?(Hash) && regex['literal'] == true
end

# Escapes the same characters as rebar (regex-syntax `escape`): every ASCII
# metacharacter. PCRE2 accepts a backslash before any ASCII punctuation.
def escape(text)
  text.gsub(/[\\.+*?()|\[\]{}^$#&\-~]/) { |char| "\\#{char}" }
end

def haystack_spec(haystack)
  return { 'contents' => haystack } if haystack.is_a?(String)

  spec = {}
  spec['path'] = haystack['path'] if haystack.key?('path')
  spec['contents'] = haystack['contents'] if haystack.key?('contents')
  spec['utf8_lossy'] = haystack['utf8-lossy'] == true
  spec['trim'] = haystack['trim'] == true
  spec['line_start'] = haystack['line-start'] if haystack.key?('line-start')
  spec['line_end'] = haystack['line-end'] if haystack.key?('line-end')
  spec['repeat'] = haystack['repeat'] if haystack.key?('repeat')
  spec['prepend'] = haystack['prepend'] if haystack.key?('prepend')
  spec['append'] = haystack['append'] if haystack.key?('append')
  spec
end

def convert(source)
  benchmarks_dir = extract_dir(source)
  definitions_dir = File.join(benchmarks_dir, 'definitions')
  abort "#{definitions_dir} is missing; run the fetch step first" unless Dir.exist?(definitions_dir)

  cases = []
  excluded = []
  Dir.glob(File.join(definitions_dir, '**', '*.toml')).sort.each do |path|
    relative = path.sub("#{definitions_dir}/", '').sub(/\.toml\z/, '')
    parsed = TomlSubset.new(File.read(path, encoding: 'UTF-8'), relative).parse
    parsed.fetch('bench').each do |bench|
      id = "#{relative}/#{bench.fetch('name')}"
      model = bench.fetch('model')
      engines = bench.fetch('engines')
      reason = nil
      reason = "model #{model} is not implemented by the harness" unless SUPPORTED_MODELS.include?(model)
      reason ||= "rebar does not list #{BASELINE_ENGINE} for this benchmark" unless engines.include?(BASELINE_ENGINE)
      patterns = reason ? [] : resolve_patterns(bench.fetch('regex'), benchmarks_dir)
      reason ||= "#{patterns.size} patterns (the engines under test take one)" unless patterns.size == 1
      expected = expected_count_for(bench.fetch('count'), BASELINE_ENGINE)
      reason ||= "no expected count for #{BASELINE_ENGINE}" if expected.nil?
      if reason
        excluded << { 'id' => id, 'reason' => reason }
        next
      end

      cases << {
        'id' => id,
        'group' => "rebar/#{relative.split('/').first}",
        'subgroup' => "rebar/#{relative}",
        'model' => model,
        'pattern' => patterns.first,
        'case_insensitive' => bench['case-insensitive'] == true,
        'unicode' => bench['unicode'] == true,
        'haystack' => haystack_spec(bench.fetch('haystack')),
        'expected_count' => expected
      }
    end
  end

  document = {
    'source' => source,
    'converted_by' => 'bench/regex/scripts/rebar_corpus.rb',
    'baseline_engine' => BASELINE_ENGINE,
    'case_count' => cases.size,
    'excluded_count' => excluded.size,
    'cases' => cases,
    'excluded' => excluded
  }
  output_path = File.join(benchmarks_dir, 'rebar.json')
  File.write(output_path, JSON.pretty_generate(document) + "\n")
  puts "wrote #{output_path}: #{cases.size} cases, #{excluded.size} excluded"
end

source = load_source
case ARGV.first
when 'fetch' then fetch(source)
when 'convert' then convert(source)
when nil
  fetch(source)
  convert(source)
else
  abort 'usage: rebar_corpus.rb [fetch|convert]'
end
