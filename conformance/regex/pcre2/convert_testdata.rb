# Fetches the PCRE2 release tarball named in manifest.json, checks its
# sha256, and converts every pattern in its testdata/testinput* files into
# spec/regex/fixtures/pcre2_syntax_cases.json: one case per pattern, with the
# pattern bytes and its pcre2test modifiers. Subject lines are not needed for
# the syntax census (milestone R1) and are skipped.
#
#   /usr/bin/ruby conformance/regex/pcre2/convert_testdata.rb
#
# The download is cached under tmp/regex-corpora/ (git-ignored). A sha256
# mismatch stops the script before anything is read from the archive.
require "json"
require "digest"
require "fileutils"
require "open3"

ROOT = File.expand_path("../../..", __dir__)
MANIFEST = JSON.parse(File.read(File.join(__dir__, "manifest.json")))
CACHE = File.join(ROOT, "tmp", "regex-corpora")
OUTPUT = File.join(ROOT, "spec", "regex", "fixtures", "pcre2_syntax_cases.json")

# pcre2test's single-letter modifiers (c1modlist in pcre2test.c).
SINGLE_LETTER = {
  "B" => "bincode", "I" => "info", "a" => "ascii_all", "g" => "global",
  "i" => "caseless", "m" => "multiline", "n" => "no_auto_capture",
  "r" => "caseless_restrict", "s" => "dotall", "x" => "extended",
}.freeze

DELIMITERS = "/!\"'`-=_:;,%&@~".chars.freeze

def fetch_archive
  FileUtils.mkdir_p(CACHE)
  path = File.join(CACHE, MANIFEST.fetch("archive"))
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

def extract(archive)
  target = File.join(CACHE, "pcre2-#{MANIFEST.fetch("version")}")
  unless Dir.exist?(target)
    _, status = Open3.capture2("tar", "-xzf", archive, "-C", CACHE)
    abort("tar failed for #{archive}") unless status.success?
  end
  File.join(target, "testdata")
end

# Splits a modifier string the way pcre2test's decode_modifiers does: items
# separated by commas; the first item may be a run of single letters, where
# a second "x" turns extended into extended_more.
def decode_modifiers(text)
  result = []
  first = true
  text.split(",").each do |raw|
    item = raw.strip
    next if item.empty?
    name = item.sub(/\A-/, "").split("=", 2).first
    if first && !known_modifier?(name)
      letters = item.chars
      letters.each_with_index do |letter, index|
        full = SINGLE_LETTER[letter]
        return [result, "unrecognized single-letter modifier #{letter.inspect}"] unless full
        if letter == "x" && result.include?("extended")
          result.delete("extended")
          result << "extended_more"
        else
          result << full
        end
      end
      # pcre2test clears its flag only after a run of single letters, so
      # one run may follow full-name modifiers.
      first = false
    elsif known_modifier?(name)
      result << item
    else
      return [result, "unrecognized modifier #{item.inspect}"]
    end
  end
  [result, nil]
end

KNOWN = %w[
  aftertext allaftertext allcaptures allow_empty_class allow_lookaround_bsk allow_surrogate_escapes
  allusedtext allvector alt_bsux alt_circumflex alt_extended_class alt_verbnames altglobal anchored
  ascii_all ascii_bsd ascii_bss ascii_bsw ascii_digit ascii_posix auto_callout auto_possess
  auto_possess_off bad_escape_is_literal bincode bsr callout_capture callout_data callout_error
  callout_extra callout_fail callout_info callout_no_where callout_none caseless caseless_restrict
  convert convert_glob_escape convert_glob_separator convert_length copy copy_matched_subject debug
  depth_limit dfa dfa_restart dfa_shortest disable_recurseloop_check dollar_endonly dotall
  dotstar_anchor dotstar_anchor_off dupnames endanchored escaped_cr_is_lf expand extended
  extended_more extra_alt_bsux find_limits find_limits_noheap firstline framesize fullbincode get
  getall global heap_limit heapframes_size hex info jit jitfast jitstack jitverify literal locale
  mark match_invalid_utf match_limit match_line match_unset_backref match_word
  max_pattern_compiled_length max_pattern_length max_varlookbehind memory multiline
  never_backslash_c never_callout never_ucp never_utf newline no_auto_capture no_auto_possess no_bs0
  no_dotstar_anchor no_jit no_start_optimize no_utf_check notbol notempty notempty_atstart noteol
  null_context null_pattern null_replacement null_subject null_substitute_match_data offset
  offset_limit optimization_full optimization_none ovector parens_nest_limit partial_hard
  partial_soft ph posix posix_nosub posix_startend ps push pushcopy pushtablescopy python_octal
  recursion_limit regerror_buffsize replace stackguard start_optimize start_optimize_off startchar
  startoffset subject_literal substitute_callout substitute_case_callout substitute_extended
  substitute_literal substitute_matched substitute_overflow_length substitute_replacement_only
  substitute_skip substitute_stop substitute_subject substitute_unknown_unset substitute_unset_empty
  tables turkish_casing ucp ungreedy use_length use_offset_limit utf utf8_input zero_terminate
].freeze

def known_modifier?(name)
  KNOWN.include?(name)
end

# Decodes a pattern given with the hex modifier: pairs of hex digits, white
# space ignored, and quoted strings taken literally.
def decode_hex(text)
  bytes = "".b
  index = 0
  while index < text.size
    char = text[index]
    if char =~ /\s/
      index += 1
    elsif char == "'" || char == '"'
      close = text.index(char, index + 1) || text.size
      bytes << text[(index + 1)...close].b
      index = close + 1
    else
      bytes << text[index, 2].to_i(16).chr
      index += 2
    end
  end
  bytes
end

# Returns why pcre2test refuses to expand the pattern, or nil. Expansion
# replaces \[text]{count} with count copies of text.
def expand_problem(pattern)
  pattern.scan(/\\\[.*?\]\{(\d+)\}/m) do |match|
    count = match.first.to_i
    return "Pattern repeat count too large" if count > 0xFFFF_FFFF
    return "Zero repeat not allowed" if count.zero?
  end
  nil
end

def condition_true?(text)
  negated = text.start_with?("!")
  name = text.sub(/\A!/, "").strip
  value = case name
          when "ebcdic", "ebcdic-nl25" then false
          when "unicode" then true
          else abort("unknown #if condition #{name}")
          end
  negated ? !value : value
end

def convert_file(path, list_of_cases)
  lines = File.binread(path).split("\n", -1)
  default_modifiers = []
  pushed_defaults = []
  skipping = []
  index = 0
  file = File.basename(path)
  while index < lines.size
    line = lines[index]
    if line.start_with?("#if ")
      skipping.push(!condition_true?(line[4..-1]))
      index += 1
      next
    elsif line.start_with?("#endif")
      skipping.pop
      index += 1
      next
    elsif skipping.include?(true)
      index += 1
      next
    end
    if line.strip.empty? || line.start_with?("# ") || line == "#"
      index += 1
      next
    end
    if line.start_with?("#")
      command, argument = line[1..-1].split(/\s+/, 2)
      if command == "pattern"
        decoded, = decode_modifiers(argument.to_s)
        decoded.each do |item|
          if item.start_with?("-")
            default_modifiers.delete(item[1..-1])
          else
            default_modifiers << item
          end
        end
      end
      pushed_defaults << command
      index += 1
      next
    end
    delimiter = line[0]
    unless DELIMITERS.include?(delimiter)
      # A subject line that follows a pattern; skip to the blank line.
      index += 1
      next
    end
    start_line = index + 1
    body = line[1..-1]
    pattern = "".b
    loop do
      close = find_closing(body, delimiter)
      if close
        pattern << body[0...close].b
        body = body[(close + 1)..-1]
        break
      end
      pattern << body.b << "\n"
      index += 1
      abort("#{file}:#{start_line}: unterminated pattern") if index >= lines.size
      body = lines[index]
    end
    if body.start_with?("\\")
      pattern << "\\"
      body = body[1..-1]
    end
    modifiers, problem = decode_modifiers(body)
    modifiers = (default_modifiers + modifiers).map { |modifier| modifier.dup.force_encoding("UTF-8").scrub("?") }
    pattern = decode_hex(pattern.force_encoding("UTF-8")) if modifiers.include?("hex")
    # Expansion happens in the Crystal fixture loader, which keeps this file
    # small; a count pcre2test refuses (above 2^32 - 1, or zero) is recorded.
    record_problem = modifiers.include?("expand") ? expand_problem(pattern) : nil
    record = {"id" => "#{file}:#{start_line}", "file" => file, "line" => start_line, "modifiers" => modifiers}
    record["modifier_problem"] = problem if problem
    record["harness_problem"] = record_problem if record_problem
    utf8 = pattern.dup.force_encoding("UTF-8")
    if utf8.valid_encoding?
      record["pattern"] = utf8
    else
      record["pattern_hex"] = pattern.unpack1("H*")
    end
    list_of_cases << record
    index += 1
    # Subject lines follow until a blank line.
    index += 1 while index < lines.size && !lines[index].strip.empty?
  end
end

# Returns the index of the closing delimiter in body, or nil. A backslash
# escapes the next character (and both stay in the pattern).
def find_closing(body, delimiter)
  index = 0
  while index < body.size
    char = body[index]
    return index if char == delimiter
    index += char == "\\" ? 2 : 1
  end
  nil
end

archive = fetch_archive
testdata = extract(archive)
files = Dir.children(testdata).select { |name| name =~ /\Atestinput(\d+|heap)\z/ }
files.sort_by! { |name| [name[/\d+/].to_i, name] }
list_of_cases = []
files.each { |name| convert_file(File.join(testdata, name), list_of_cases) }
document = {
  "source" => MANIFEST,
  "generator" => "conformance/regex/pcre2/convert_testdata.rb",
  "files" => files,
  "case_count" => list_of_cases.size,
  "cases" => list_of_cases,
}
FileUtils.mkdir_p(File.dirname(OUTPUT))
File.write(OUTPUT, JSON.pretty_generate(document) + "\n")
puts "wrote #{list_of_cases.size} cases from #{files.size} files to #{OUTPUT.sub(ROOT + "/", "")}"
