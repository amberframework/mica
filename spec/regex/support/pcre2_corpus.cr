# The PCRE2 10.49 testinput corpus (spec/regex/fixtures/pcre2_syntax_cases.json,
# converted by conformance/regex/pcre2/convert_testdata.rb) and the rules
# that map each case's pcre2test modifiers onto the Crystal dialect.
#
# Shared by the default spec suite (which never links PCRE2) and the
# differential oracle in spec/regex/differential/ (which does).
require "json"
require "../../../src/mica/regex"

module PCRE2Corpus
  CASES_PATH    = File.join(__DIR__, "..", "fixtures", "pcre2_syntax_cases.json")
  VERDICTS_PATH = File.join(__DIR__, "..", "fixtures", "pcre2_syntax_verdicts.json")

  # One pattern from a testinput file.
  struct Case
    include JSON::Serializable

    getter id : String = ""
    getter file : String = ""
    getter line : Int32 = 0
    getter modifiers : Array(String) = [] of String
    getter pattern : String? = nil
    getter pattern_hex : String? = nil
    getter modifier_problem : String? = nil
    getter harness_problem : String? = nil

    # The pattern bytes pcre2test passes to pcre2_compile (after `expand`).
    def pattern_bytes : Bytes
      raw = if hex = pattern_hex
              hex.hexbytes
            else
              (pattern || "").to_slice
            end
      return raw unless active_modifiers.includes?("expand")
      PCRE2Corpus.expand(raw)
    end

    # The modifiers in force, with `-name` entries removing earlier ones.
    def active_modifiers : Array(String)
      result = [] of String
      modifiers.each do |modifier|
        if modifier.starts_with?('-')
          result.delete(modifier[1..])
        else
          result << modifier
        end
      end
      result
    end
  end

  # The fixture file.
  struct Corpus
    include JSON::Serializable

    getter case_count : Int32 = 0
    getter list_of_files : Array(String) = [] of String
    getter cases : Array(Case) = [] of Case

    @[JSON::Field(key: "files")]
    @list_of_files : Array(String) = [] of String
  end

  # How a case's modifiers relate to the Crystal dialect.
  enum Scope
    # pcre2test itself rejects the case before compiling (unknown modifier,
    # a repeat count it cannot expand).
    HarnessRejected
    # A compile option the Crystal dialect has no way to express.
    OutsideDialect
    # Compiled with the mapped options.
    InDialect
  end

  # pcre2test modifiers that change pattern syntax or semantics in ways the
  # Crystal dialect cannot express (Crystal's Regex::CompileOptions have no
  # equivalent and the pattern has no inline form).
  OUTSIDE_DIALECT_MODIFIERS = {
    "allow_empty_class", "allow_lookaround_bsk", "allow_surrogate_escapes", "alt_bsux", "alt_circumflex",
    "alt_extended_class", "alt_verbnames", "auto_callout", "bad_escape_is_literal", "bsr", "convert",
    "convert_glob_escape", "convert_glob_separator", "convert_length", "escaped_cr_is_lf", "extra_alt_bsux",
    "literal", "locale", "match_line", "match_unset_backref", "match_word", "max_pattern_compiled_length",
    "max_pattern_length", "max_varlookbehind", "never_backslash_c", "never_callout", "never_ucp", "never_utf",
    "newline", "no_bs0", "no_utf_check", "parens_nest_limit", "posix", "posix_nosub", "python_octal", "tables",
    "turkish_casing", "utf8_input", "null_pattern", "stackguard", "regerror_buffsize", "pushtablescopy",
  }

  # Modifiers that map onto `Mica::Regex::CompileOptions`.
  OPTION_MODIFIERS = {
    "caseless"          => Mica::Regex::CompileOptions::IgnoreCase,
    "multiline"         => Mica::Regex::CompileOptions::Multiline,
    "dotall"            => Mica::Regex::CompileOptions::DotAll,
    "extended"          => Mica::Regex::CompileOptions::Extended,
    "extended_more"     => Mica::Regex::CompileOptions::Extended | Mica::Regex::CompileOptions::ExtendedMore,
    "anchored"          => Mica::Regex::CompileOptions::Anchored,
    "dollar_endonly"    => Mica::Regex::CompileOptions::DollarEndOnly,
    "firstline"         => Mica::Regex::CompileOptions::FirstLine,
    "endanchored"       => Mica::Regex::CompileOptions::EndAnchored,
    "match_invalid_utf" => Mica::Regex::CompileOptions::MatchInvalidUtf,
    "ungreedy"          => Mica::Regex::CompileOptions::Ungreedy,
    "no_auto_capture"   => Mica::Regex::CompileOptions::NoAutoCapture,
    "caseless_restrict" => Mica::Regex::CompileOptions::CaselessRestrict,
    "ascii_bsd"         => Mica::Regex::CompileOptions::AsciiBackslashD,
    "ascii_bss"         => Mica::Regex::CompileOptions::AsciiBackslashS,
    "ascii_bsw"         => Mica::Regex::CompileOptions::AsciiBackslashW,
    "ascii_posix"       => Mica::Regex::CompileOptions::AsciiPosix,
    "ascii_digit"       => Mica::Regex::CompileOptions::AsciiDigit,
    "ascii_all"         => Mica::Regex::CompileOptions::ASCII_ALL,
  }

  # Returns the scope of *test_case* and, when outside the dialect, the
  # modifier responsible.
  def self.scope_of(test_case : Case) : {Scope, String?}
    if problem = test_case.modifier_problem || test_case.harness_problem
      return {Scope::HarnessRejected, problem}
    end
    test_case.active_modifiers.each do |modifier|
      name = modifier.split('=', 2).first
      return {Scope::OutsideDialect, name} if OUTSIDE_DIALECT_MODIFIERS.includes?(name)
    end
    {Scope::InDialect, nil}
  end

  # The Mica options for *test_case* (UTF, UCP and DUPNAMES are implicit).
  def self.options_of(test_case : Case) : Mica::Regex::CompileOptions
    options = Mica::Regex::CompileOptions::None
    test_case.active_modifiers.each do |modifier|
      if flags = OPTION_MODIFIERS[modifier]?
        options |= flags
      end
    end
    options
  end

  # pcre2test's `expand`: `\[text]{count}` becomes count copies of text.
  def self.expand(raw : Bytes) : Bytes
    io = IO::Memory.new
    index = 0
    while index < raw.size
      if raw[index] == '\\'.ord && index + 1 < raw.size && raw[index + 1] == '['.ord
        close = find_close(raw, index + 2)
        if close
          text_end, count, after = close
          count.times { io.write(raw[index + 2, text_end - index - 2]) }
          index = after
          next
        end
      end
      io.write_byte(raw[index])
      index += 1
    end
    io.to_slice
  end

  # Finds `]{digits}` after *start*: returns {text end, count, offset after}.
  private def self.find_close(raw : Bytes, start : Int32) : {Int32, Int32, Int32}?
    position = start
    while position + 1 < raw.size
      if raw[position] == ']'.ord && raw[position + 1] == '{'.ord
        digits = position + 2
        cursor = digits
        while cursor < raw.size && '0'.ord <= raw[cursor] <= '9'.ord
          cursor += 1
        end
        if cursor > digits && cursor < raw.size && raw[cursor] == '}'.ord
          return {position, String.new(raw[digits, cursor - digits]).to_i, cursor + 1}
        end
      end
      position += 1
    end
    nil
  end

  def self.load : Corpus
    Corpus.from_json(File.read(CASES_PATH))
  end

  # PCRE2's verdict for one case, recorded by the differential oracle.
  struct Verdict
    include JSON::Serializable

    getter id : String = ""
    getter? accepted : Bool = false
    getter error_code : Int32 = 0
    getter error_offset : Int64 = 0
    getter error_message : String = ""
    getter capture_count : Int32 = 0
    getter list_of_group_names : Array(String) = [] of String

    def initialize(@id : String, @accepted : Bool, @error_code : Int32, @error_offset : Int64, @error_message : String,
                   @capture_count : Int32, @list_of_group_names : Array(String))
    end
  end

  # The oracle's output file.
  struct VerdictFile
    include JSON::Serializable

    getter pcre2_version : String = ""
    getter compile_options : String = ""
    getter list_of_verdicts : Array(Verdict) = [] of Verdict

    def initialize(@pcre2_version : String, @compile_options : String, @list_of_verdicts : Array(Verdict))
    end
  end

  def self.load_verdicts : Hash(String, Verdict)
    file = VerdictFile.from_json(File.read(VERDICTS_PATH))
    file.list_of_verdicts.to_h { |verdict| {verdict.id, verdict} }
  end
end
