# The PCRE2 syntax oracle: compiles every in-dialect pattern of the PCRE2
# 10.49 testinput corpus with libpcre2-8 under the options Crystal's stdlib
# Regex uses (UTF | UCP | DUPNAMES plus the case's mapped options) and
# records PCRE2's verdict in spec/regex/fixtures/pcre2_syntax_verdicts.json.
#
# This is the only Mica file that links PCRE2. It is a standalone program,
# not a spec, so `crystal-alpha spec` never compiles it; run it by hand when
# the corpus or the PCRE2 version changes:
#
#     crystal-alpha run spec/regex/differential/pcre2_syntax_oracle.cr
#
# It refuses to run against any PCRE2 other than the one the corpus
# manifest pins (conformance/regex/pcre2/manifest.json).
require "json"
require "../support/pcre2_corpus"

# The compile-context calls Crystal's stdlib binding (LibPCRE2) leaves out;
# everything else goes through LibPCRE2 itself.
@[Link("pcre2-8")]
lib LibPCRE2Oracle
  fun compile_context_create = pcre2_compile_context_create_8(gcontext : Void*) : LibPCRE2::CompileContext*
  fun compile_context_free = pcre2_compile_context_free_8(ccontext : LibPCRE2::CompileContext*)
  fun set_compile_extra_options = pcre2_set_compile_extra_options_8(ccontext : LibPCRE2::CompileContext*, extra : UInt32) : Int32
end

module PCRE2SyntaxOracle
  # pcre2.h option bits.
  UTF               = 0x00080000_u32
  UCP               = 0x00020000_u32
  DUPNAMES          = 0x00000040_u32
  INFO_CAPTURECOUNT =          4_u32
  INFO_NAMECOUNT    =         17_u32
  INFO_ENTRYSIZE    =         18_u32
  INFO_NAMETABLE    =         19_u32
  CONFIG_VERSION    =         11_u32

  MAIN_OPTIONS = {
    Mica::Regex::CompileOptions::IgnoreCase      => 0x00000008_u32,
    Mica::Regex::CompileOptions::Multiline       => 0x00000400_u32,
    Mica::Regex::CompileOptions::DotAll          => 0x00000020_u32,
    Mica::Regex::CompileOptions::Extended        => 0x00000080_u32,
    Mica::Regex::CompileOptions::ExtendedMore    => 0x01000000_u32,
    Mica::Regex::CompileOptions::Anchored        => 0x80000000_u32,
    Mica::Regex::CompileOptions::DollarEndOnly   => 0x00000010_u32,
    Mica::Regex::CompileOptions::FirstLine       => 0x00000100_u32,
    Mica::Regex::CompileOptions::EndAnchored     => 0x20000000_u32,
    Mica::Regex::CompileOptions::MatchInvalidUtf => 0x04000000_u32,
    Mica::Regex::CompileOptions::Ungreedy        => 0x00040000_u32,
    Mica::Regex::CompileOptions::NoAutoCapture   => 0x00002000_u32,
  }

  EXTRA_OPTIONS = {
    Mica::Regex::CompileOptions::CaselessRestrict => 0x00000080_u32,
    Mica::Regex::CompileOptions::AsciiBackslashD  => 0x00000100_u32,
    Mica::Regex::CompileOptions::AsciiBackslashS  => 0x00000200_u32,
    Mica::Regex::CompileOptions::AsciiBackslashW  => 0x00000400_u32,
    Mica::Regex::CompileOptions::AsciiPosix       => 0x00000800_u32,
    Mica::Regex::CompileOptions::AsciiDigit       => 0x00001000_u32,
  }

  def self.pcre2_version : String
    buffer = Bytes.new(64)
    LibPCRE2.config(CONFIG_VERSION, buffer.to_unsafe.as(Void*))
    String.new(buffer.to_unsafe)
  end

  def self.pinned_version : String
    manifest = File.read(File.join(__DIR__, "..", "..", "..", "conformance", "regex", "pcre2", "manifest.json"))
    PinnedManifest.from_json(manifest).version
  end

  struct PinnedManifest
    include JSON::Serializable
    getter version : String = ""
  end

  def self.verdict_for(test_case : PCRE2Corpus::Case) : PCRE2Corpus::Verdict
    options = PCRE2Corpus.options_of(test_case)
    main = UTF | UCP | DUPNAMES
    extra = 0_u32
    MAIN_OPTIONS.each { |flag, bit| main |= bit if options.includes?(flag) }
    EXTRA_OPTIONS.each { |flag, bit| extra |= bit if options.includes?(flag) }
    context = LibPCRE2Oracle.compile_context_create(Pointer(Void).null)
    LibPCRE2Oracle.set_compile_extra_options(context, extra)
    bytes = test_case.pattern_bytes
    error_code = 0
    error_offset = LibC::SizeT.new(0)
    code = LibPCRE2.compile(bytes.to_unsafe, LibC::SizeT.new(bytes.size), main, pointerof(error_code),
      pointerof(error_offset), context)
    LibPCRE2Oracle.compile_context_free(context)
    if code.null?
      message = Bytes.new(256)
      LibPCRE2.get_error_message(error_code, message.to_unsafe, LibC::SizeT.new(message.size))
      return PCRE2Corpus::Verdict.new(test_case.id, false, error_code, error_offset.to_i64,
        String.new(message.to_unsafe), 0, [] of String)
    end
    capture_count = 0_u32
    LibPCRE2.pattern_info(code, INFO_CAPTURECOUNT, pointerof(capture_count).as(Void*))
    list_of_names = group_names_of(code)
    LibPCRE2.code_free(code)
    PCRE2Corpus::Verdict.new(test_case.id, true, 0, 0_i64, "", capture_count.to_i32, list_of_names)
  end

  # The name table, as "number:name" entries in table order.
  def self.group_names_of(code : LibPCRE2::Code*) : Array(String)
    count = 0_u32
    entry_size = 0_u32
    table = Pointer(UInt8).null
    LibPCRE2.pattern_info(code, INFO_NAMECOUNT, pointerof(count).as(Void*))
    LibPCRE2.pattern_info(code, INFO_ENTRYSIZE, pointerof(entry_size).as(Void*))
    LibPCRE2.pattern_info(code, INFO_NAMETABLE, pointerof(table).as(Void*))
    list_of_names = [] of String
    count.times do |index|
      entry = table + index * entry_size
      number = (entry[0].to_i32 << 8) | entry[1].to_i32
      list_of_names << "#{number}:#{String.new(entry + 2)}"
    end
    list_of_names
  end

  def self.run : Nil
    version = pcre2_version
    pinned = pinned_version
    unless version.starts_with?(pinned)
      abort "PCRE2 #{version} is linked, but the corpus manifest pins #{pinned}; install that version first."
    end
    corpus = PCRE2Corpus.load
    list_of_verdicts = [] of PCRE2Corpus::Verdict
    corpus.cases.each do |test_case|
      scope, _reason = PCRE2Corpus.scope_of(test_case)
      next unless scope.in_dialect?
      list_of_verdicts << verdict_for(test_case)
    end
    file = PCRE2Corpus::VerdictFile.new(version, "UTF | UCP | DUPNAMES plus each case's mapped options", list_of_verdicts)
    File.write(PCRE2Corpus::VERDICTS_PATH, file.to_pretty_json + "\n")
    accepted = list_of_verdicts.count(&.accepted?)
    STDOUT.puts "PCRE2 #{version}: #{list_of_verdicts.size} in-dialect cases, #{accepted} accepted, " \
                "#{list_of_verdicts.size - accepted} rejected -> #{PCRE2Corpus::VERDICTS_PATH}"
  end
end

PCRE2SyntaxOracle.run
