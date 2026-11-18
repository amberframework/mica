require "../spec_helper"
require "./support/conformance_approval"
require "./support/pcre2_corpus"

# The PCRE2 10.49 syntax census. Every pattern in the testinput corpus is
# classified, and for every in-dialect case Mica's verdict is compared with
# PCRE2's (recorded by spec/regex/differential/pcre2_syntax_oracle.cr, so
# this spec never links PCRE2):
#
# - both accept: capture counts and group names must match;
# - Mica refuses an excluded construct by name: classified, as long as
#   PCRE2 accepts or rejects at the same or a later byte;
# - Mica refuses by a named compile limit: classified;
# - both report a syntax error at the same byte offset: classified as
#   invalid in both (a different offset is a mismatch);
# - otherwise the case must be listed in conformance/regex/pcre2/divergences.tsv.
#
# Set MICA_REGEX_CENSUS to a path to write the per-case table as TSV.

module PCRE2Census
  enum Category
    Accepted
    Excluded
    Limit
    InvalidInBoth
    OutsideDialect
    HarnessRejected
    ApprovedDivergence
    Mismatch
  end

  record Row, test_case : PCRE2Corpus::Case, category : Category, detail : String

  DIVERGENCES_PATH = File.join(__DIR__, "..", "..", "conformance", "regex", "pcre2", "divergences.tsv")

  # Approved divergences: case id => reason.
  def self.load_divergences : Hash(String, String)
    approved = {} of String => String
    File.each_line(DIVERGENCES_PATH) do |line|
      next if line.starts_with?('#') || line.blank?
      fields = line.split('\t')
      approved[fields[0]] = fields[1]? || ""
    end
    approved
  end

  def self.classify(test_case : PCRE2Corpus::Case, verdict : PCRE2Corpus::Verdict?,
                    approved : Hash(String, String)) : Row
    scope, reason = PCRE2Corpus.scope_of(test_case)
    if scope.harness_rejected?
      return Row.new(test_case, Category::HarnessRejected, reason || "")
    end
    options = PCRE2Corpus.options_of(test_case)
    bytes = test_case.pattern_bytes
    error = Mica::Regex::Syntax.error?(bytes, dialect: :crystal,
      compile_limits: Mica::Regex::CompileLimits::TRUSTED_PATTERN, options: options)
    if scope.outside_dialect?
      return Row.new(test_case, Category::OutsideDialect, reason || "")
    end
    unless verdict
      return Row.new(test_case, Category::Mismatch, "no PCRE2 verdict recorded; rerun the oracle")
    end
    row = compare(test_case, verdict, error, options)
    if row.category.mismatch? && (why = approved[test_case.id]?)
      return Row.new(test_case, Category::ApprovedDivergence, "#{row.detail} (approved: #{why})")
    end
    row
  end

  def self.compare(test_case : PCRE2Corpus::Case, verdict : PCRE2Corpus::Verdict, error : Mica::Error?,
                   options : Mica::Regex::CompileOptions) : Row
    if error.is_a?(Mica::Regex::UnsupportedConstructError)
      pcre2_view = verdict.accepted? ? "PCRE2 accepts" : "PCRE2 rejects at #{verdict.error_offset}: #{verdict.error_message}"
      # An excluded construct must be found no later than the error PCRE2
      # reports; PCRE2 rejecting earlier means Mica read past a syntax error.
      if !verdict.accepted? && verdict.error_offset < error.byte_offset
        return Row.new(test_case, Category::Mismatch,
          "PCRE2 rejects at #{verdict.error_offset} (#{verdict.error_message}) before Mica's #{error.construct} at byte #{error.byte_offset}")
      end
      return Row.new(test_case, Category::Excluded, "#{error.construct} at byte #{error.byte_offset}; #{pcre2_view}")
    end
    if error.is_a?(Mica::Regex::CompileLimitError)
      return Row.new(test_case, Category::Limit, error.limit_name)
    end
    if error.is_a?(Mica::WorkBudgetExceededError)
      return Row.new(test_case, Category::Limit, "compile work budget")
    end
    if error
      unless verdict.accepted?
        mica_offset = error.is_a?(Mica::ParseError) ? error.byte_offset : -1_i64
        detail = "PCRE2 #{verdict.error_code} at #{verdict.error_offset} (#{verdict.error_message}); Mica: #{error.message}"
        unless mica_offset == verdict.error_offset
          return Row.new(test_case, Category::Mismatch, "offset differs: #{detail}")
        end
        return Row.new(test_case, Category::InvalidInBoth, "same offset: #{detail}")
      end
      return Row.new(test_case, Category::Mismatch, "PCRE2 accepts; Mica: #{error.message}")
    end
    unless verdict.accepted?
      return Row.new(test_case, Category::Mismatch,
        "Mica accepts; PCRE2 #{verdict.error_code} at #{verdict.error_offset}: #{verdict.error_message}")
    end
    report = Mica::Regex::Syntax.check(test_case.pattern_bytes, dialect: :crystal,
      compile_limits: Mica::Regex::CompileLimits::TRUSTED_PATTERN, options: options)
    mica_names = report.list_of_group_names.sort_by { |entry| {entry.capture_index, entry.group_name} }
      .map { |entry| "#{entry.capture_index}:#{entry.group_name}" }
    pcre2_names = verdict.list_of_group_names.sort
    if report.capture_count != verdict.capture_count || mica_names.sort != pcre2_names
      return Row.new(test_case, Category::Mismatch,
        "captures #{report.capture_count} vs #{verdict.capture_count}; names #{mica_names} vs #{pcre2_names}")
    end
    Row.new(test_case, Category::Accepted, "")
  end
end

describe "PCRE2 10.49 syntax census" do
  it_satisfies "REGEX-R1-pcre2-census", "classifies every testinput pattern with zero unexplained mismatches" do
    corpus = PCRE2Corpus.load
    verdicts = PCRE2Corpus.load_verdicts
    approved = PCRE2Census.load_divergences
    list_of_rows = corpus.cases.map { |test_case| PCRE2Census.classify(test_case, verdicts[test_case.id]?, approved) }
    if path = ENV["MICA_REGEX_CENSUS"]?
      File.open(path, "w") do |file|
        file << "id\tcategory\tdetail\n"
        list_of_rows.each { |row| file << row.test_case.id << '\t' << row.category << '\t' << row.detail.gsub(/\s+/, " ") << '\n' }
      end
    end
    counts = list_of_rows.group_by(&.category).transform_values(&.size)
    list_of_rows.size.should eq(corpus.case_count)
    list_of_mismatches = list_of_rows.select(&.category.mismatch?).map { |row| "#{row.test_case.id} #{row.detail}" }
    list_of_mismatches.first(40).should eq([] of String)
    counts[PCRE2Census::Category::Accepted]?.should_not be_nil
    # Every approved divergence still diverges, so the list cannot go stale.
    used = list_of_rows.select(&.category.approved_divergence?).map(&.test_case.id).to_set
    (approved.keys.to_set - used).should eq(Set(String).new)
    # Every approved divergence names a code owner as its approver.
    ConformanceApproval.unapproved(ConformanceApproval.read_rows(PCRE2Census::DIVERGENCES_PATH)).should eq([] of String)
  end
end
