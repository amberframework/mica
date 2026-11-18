# The PCRE2 search oracle: runs every in-scope case of the RE2 and Rust
# regex search corpora (spec/regex/support/search_corpus.cr maps them onto
# the Crystal dialect) through libpcre2-8, with the options Crystal's stdlib
# Regex compiles with (UTF | UCP | DUPNAMES plus the case's mapped options)
# and String#scan's iteration rule, and records each outcome in
# spec/regex/fixtures/pcre2_search_verdicts.json.
#
# The conformance spec reads those outcomes to tell a Mica defect from a
# difference between the corpus engine (RE2, Rust regex) and the Crystal
# dialect: a case whose corpus expectation differs from Mica's result can
# be an approved divergence only when PCRE2 gives exactly Mica's result.
#
# Like the syntax oracle next to it, this is a standalone program, never
# compiled by `crystal-alpha spec`; run it by hand when a corpus or the
# mapping changes:
#
#     crystal-alpha run spec/regex/differential/pcre2_search_oracle.cr
#
# It refuses to run against any PCRE2 other than the one
# conformance/regex/pcre2/manifest.json pins.
require "json"
require "../support/search_corpus"

@[Link("pcre2-8")]
lib LibPCRE2SearchOracle
  fun compile_context_create = pcre2_compile_context_create_8(gcontext : Void*) : LibPCRE2::CompileContext*
  fun compile_context_free = pcre2_compile_context_free_8(ccontext : LibPCRE2::CompileContext*)
  fun set_compile_extra_options = pcre2_set_compile_extra_options_8(ccontext : LibPCRE2::CompileContext*, extra : UInt32) : Int32
end

module PCRE2SearchOracle
  UTF               = 0x00080000_u32
  UCP               = 0x00020000_u32
  DUPNAMES          = 0x00000040_u32
  ANCHORED          = 0x80000000_u32
  NO_UTF_CHECK      = 0x40000000_u32
  INFO_CAPTURECOUNT =          4_u32
  CONFIG_VERSION    =         11_u32
  ERROR_NOMATCH     =             -1

  MAIN_OPTIONS = {
    Mica::Regex::CompileOptions::IgnoreCase    => 0x00000008_u32,
    Mica::Regex::CompileOptions::Multiline     => 0x00000400_u32,
    Mica::Regex::CompileOptions::DotAll        => 0x00000020_u32,
    Mica::Regex::CompileOptions::Extended      => 0x00000080_u32,
    Mica::Regex::CompileOptions::Anchored      => 0x80000000_u32,
    Mica::Regex::CompileOptions::DollarEndOnly => 0x00000010_u32,
    Mica::Regex::CompileOptions::FirstLine     => 0x00000100_u32,
    Mica::Regex::CompileOptions::EndAnchored   => 0x20000000_u32,
    Mica::Regex::CompileOptions::Ungreedy      => 0x00040000_u32,
    Mica::Regex::CompileOptions::NoAutoCapture => 0x00002000_u32,
  }

  EXTRA_OPTIONS = {
    Mica::Regex::CompileOptions::CaselessRestrict => 0x00000080_u32,
    Mica::Regex::CompileOptions::AsciiBackslashD  => 0x00000100_u32,
    Mica::Regex::CompileOptions::AsciiBackslashS  => 0x00000200_u32,
    Mica::Regex::CompileOptions::AsciiBackslashW  => 0x00000400_u32,
    Mica::Regex::CompileOptions::AsciiPosix       => 0x00000800_u32,
    Mica::Regex::CompileOptions::AsciiDigit       => 0x00001000_u32,
  }

  struct PinnedManifest
    include JSON::Serializable
    getter version : String = ""
  end

  def self.pcre2_version : String
    buffer = Bytes.new(64)
    LibPCRE2.config(CONFIG_VERSION, buffer.to_unsafe.as(Void*))
    String.new(buffer.to_unsafe)
  end

  def self.pinned_version : String
    path = File.join(SearchCorpus::CONFORMANCE, "pcre2", "manifest.json")
    PinnedManifest.from_json(File.read(path)).version
  end

  def self.outcome_for(job : SearchCorpus::Job) : SearchCorpus::Outcome
    main = UTF | UCP | DUPNAMES
    extra = 0_u32
    MAIN_OPTIONS.each { |flag, bit| main |= bit if job.compile_options.includes?(flag) }
    EXTRA_OPTIONS.each { |flag, bit| extra |= bit if job.compile_options.includes?(flag) }
    context = LibPCRE2SearchOracle.compile_context_create(Pointer(Void).null)
    LibPCRE2SearchOracle.set_compile_extra_options(context, extra)
    pattern = job.pattern.to_slice
    error_code = 0
    error_offset = LibC::SizeT.new(0)
    code = LibPCRE2.compile(pattern.to_unsafe, LibC::SizeT.new(pattern.size), main, pointerof(error_code),
      pointerof(error_offset), context)
    LibPCRE2SearchOracle.compile_context_free(context)
    if code.null?
      message = Bytes.new(256)
      LibPCRE2.get_error_message(error_code, message.to_unsafe, LibC::SizeT.new(message.size))
      return SearchCorpus::Outcome.compile_error(job.id, "pcre2", String.new(message.to_unsafe))
    end
    capture_count = 0_u32
    LibPCRE2.pattern_info(code, INFO_CAPTURECOUNT, pointerof(capture_count).as(Void*))
    match_data = LibPCRE2.match_data_create_from_pattern(code, nil)
    haystack = job.haystack.to_slice
    list_of_matches = [] of SearchCorpus::Spans
    offset = job.start
    match_flags = job.match_options.anchored? ? ANCHORED : 0_u32
    while offset <= haystack.size
      result = LibPCRE2.match(code, haystack.to_unsafe, LibC::SizeT.new(haystack.size), LibC::SizeT.new(offset),
        match_flags, match_data, nil)
      break if result == ERROR_NOMATCH
      if result < 0
        message = Bytes.new(256)
        LibPCRE2.get_error_message(result, message.to_unsafe, LibC::SizeT.new(message.size))
        LibPCRE2.match_data_free(match_data)
        LibPCRE2.code_free(code)
        return SearchCorpus::Outcome.compile_error(job.id, "pcre2-match", String.new(message.to_unsafe))
      end
      ovector = LibPCRE2.get_ovector_pointer(match_data)
      spans = (0..capture_count.to_i32).map do |group|
        first = ovector[group * 2]
        last = ovector[group * 2 + 1]
        first == LibC::SizeT::MAX ? nil : [first.to_i32, last.to_i32]
      end
      list_of_matches << spans
      break unless job.iterate
      break if (limit = job.match_limit) && list_of_matches.size >= limit
      first_span = spans[0] || abort("#{job.id}: group 0 unset")
      offset = SearchCorpus.next_offset(job.haystack, first_span[0], first_span[1])
      match_flags |= NO_UTF_CHECK
    end
    LibPCRE2.match_data_free(match_data)
    LibPCRE2.code_free(code)
    SearchCorpus::Outcome.new(job.id, true, "", "", list_of_matches)
  end

  def self.run : Nil
    version = pcre2_version
    pinned = pinned_version
    unless version.starts_with?(pinned)
      abort "PCRE2 #{version} is linked, but the PCRE2 manifest pins #{pinned}; install that version first."
    end
    list_of_outcomes = [] of SearchCorpus::Outcome
    SearchCorpus::Corpus.each do |corpus|
      SearchCorpus.scoped(corpus).each do |_id, _pattern, scoped|
        if job = scoped.job
          list_of_outcomes << outcome_for(job)
        end
      end
    end
    file = SearchCorpus::VerdictFile.new(version, list_of_outcomes)
    File.write(SearchCorpus::VERDICTS_PATH, file.to_pretty_json + "\n")
    STDOUT.puts "PCRE2 #{version}: #{list_of_outcomes.size} in-scope cases -> #{SearchCorpus::VERDICTS_PATH}"
  end
end

PCRE2SearchOracle.run
