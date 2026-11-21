require "../spec_helper"
require "./support/pcre2_search_corpus"
require "./support/conformance_approval"
require "./search_conformance_spec"

# The PCRE2 testdata search replay of milestone R3 (roadmap 6.5): every
# subject line of the PCRE2 10.49 testinput files, restricted to valid
# UTF-8, searched on every Mica engine path and compared with PCRE2's own
# result (recorded by spec/regex/differential/pcre2_testdata_search_oracle.cr).
#
# Every subject lands in exactly one list, as in the RE2 and Rust gates:
#
# - **excluded** (conformance/regex/pcre2/search_excluded.tsv): outside the
#   replay (see `PCRE2SearchCorpus.scope`), a construct the dialect leaves
#   out, a compile limit, or a pattern PCRE2 rejects too;
# - **divergent** (search_divergences.tsv): Mica and PCRE2 disagree. Each
#   row is a deviation from the Crystal dialect that the code owner must
#   approve (or a defect to fix); an unapproved row fails the gate;
# - **resource-limit** (search_resource_limits.tsv): the pattern sets its
#   own match, depth or heap limit with (*LIMIT_MATCH=...),
#   (*LIMIT_DEPTH=...) or (*LIMIT_HEAP=...), and PCRE2 gives up there.
#   These rows test how PCRE2 stops a runaway match, not what a pattern
#   means, so they leave the replay; spec/regex/bail_early_spec.cr proves
#   Mica stops the same patterns under its own work budget and deadline.
#   Each row needs the code owner's approval, as a divergence does;
# - **eligible**: every other subject; each must give PCRE2's result on every
#   engine path.
#
# search_denominator.json pins the counts; MICA_REGEX_CONFORMANCE_WRITE=1
# rewrites the lists from a run.
module PCRE2SearchReplay
  DIRECTORY             = PCRE2SearchCorpus::DIRECTORY
  RESOURCE_LIMITS_PATH  = PCRE2SearchCorpus::RESOURCE_LIMITS_PATH
  RESOURCE_LIMIT_REASON = "PCRE2 resource-limit test, covered by the bail-early suite"

  # The replay's counts (search_denominator.json).
  struct Denominator
    include JSON::Serializable

    getter total : Int32
    getter excluded : Int32
    getter divergent : Int32
    getter resource_limited : Int32
    getter eligible : Int32

    def initialize(@total : Int32, @excluded : Int32, @divergent : Int32, @resource_limited : Int32,
                   @eligible : Int32)
    end
  end

  def self.classify(verdicts : Hash(String, SearchCorpus::Outcome)) : Array(SearchConformance::Classified)
    PCRE2SearchCorpus.scoped.map do |id, pattern, scoped|
      job = scoped.job
      next SearchConformance::Classified.new(id, pattern, "excluded", scoped.exclusion || "") unless job
      classify_job(id, pattern, job, verdicts[id]?)
    end
  end

  def self.classify_job(id : String, pattern : String, job : SearchCorpus::Job,
                        verdict : SearchCorpus::Outcome?) : SearchConformance::Classified
    return SearchConformance::Classified.new(id, pattern, "failed", "no PCRE2 verdict recorded") unless verdict
    mica = SearchCorpus.run_mica(job)
    unless mica.compiled?
      case mica.error_kind
      when "unsupported"
        return SearchConformance::Classified.new(id, pattern, "excluded", "excluded construct: #{mica.error}")
      when "limit"
        return SearchConformance::Classified.new(id, pattern, "excluded", "refused by the compile limit #{mica.error}")
      when "search-limit"
        return SearchConformance::Classified.new(id, pattern, "excluded", "runs out of the search limit #{mica.error}")
      end
    end
    if !verdict.compiled? && verdict.error_kind == "pcre2-match" && mica.compiled? && PCRE2SearchCorpus.sets_a_resource_limit?(pattern)
      return SearchConformance::Classified.new(id, pattern, "resource-limit", RESOURCE_LIMIT_REASON)
    end
    if !verdict.compiled? && verdict.error_kind == "pcre2-match" && mica.compiled?
      return SearchConformance::Classified.new(id, pattern, "divergent",
        "PCRE2 stops at a match-time limit (#{verdict.error}) the pattern sets with (*LIMIT_...), which Mica reads and ignores; Mica gives #{mica.describe}")
    end
    unless verdict.compiled?
      if mica.compiled?
        return SearchConformance::Classified.new(id, pattern, "divergent", "PCRE2 rejects the pattern (#{verdict.error}); Mica compiles it")
      end
      return SearchConformance::Classified.new(id, pattern, "excluded", "PCRE2 and Mica both reject the pattern")
    end
    unless mica.compiled?
      return SearchConformance::Classified.new(id, pattern, "divergent", "Mica rejects the pattern (#{mica.error}); PCRE2 compiles it")
    end
    unless verdict.same_result?(mica)
      return SearchConformance::Classified.new(id, pattern, "divergent",
        "PCRE2 10.49 gives #{verdict.describe}; Mica gives #{mica.describe}")
    end
    mismatch = SearchConformance.engine_mismatch(job, mica)
    return SearchConformance::Classified.new(id, pattern, "failed", mismatch) if mismatch
    SearchConformance::Classified.new(id, pattern, "passed", "")
  end

  def self.write_lists(rows : Array(SearchConformance::Classified)) : Nil
    File.open(File.join(DIRECTORY, "search_excluded.tsv"), "w") do |file|
      file << "# PCRE2 testdata subjects outside the search replay (roadmap 6.5). id<TAB>reason\n"
      rows.each { |row| file << row.id << '\t' << row.reason << '\n' if row.category == "excluded" }
    end
    divergences_path = File.join(DIRECTORY, "search_divergences.tsv")
    previous = ConformanceApproval.read_rows(divergences_path)
    File.open(divergences_path, "w") do |file|
      file << "# Subjects where Mica's result differs from PCRE2 10.49's, each a deviation for the code owner to approve or a defect to fix.\n"
      file << "# id<TAB>reason<TAB>approval (`approved by @login`, a code owner of /conformance/regex/)\n"
      rows.each do |row|
        next unless row.category == "divergent"
        approval = previous[row.id]?.try(&.approval) || ConformanceApproval::PENDING
        file << row.id << '\t' << row.reason << '\t' << approval << '\n'
      end
    end
    write_resource_limits(rows)
    counts = Denominator.new(rows.size, rows.count(&.category.==("excluded")), rows.count(&.category.==("divergent")),
      rows.count(&.category.==("resource-limit")), rows.count { |row| row.category == "passed" || row.category == "failed" })
    File.write(File.join(DIRECTORY, "search_denominator.json"), counts.to_pretty_json + "\n")
  end

  # Writes search_resource_limits.tsv, keeping each row's approval from the
  # previous file and marking a new row pending.
  private def self.write_resource_limits(rows : Array(SearchConformance::Classified)) : Nil
    previous = ConformanceApproval.read_rows(RESOURCE_LIMITS_PATH)
    File.open(RESOURCE_LIMITS_PATH, "w") do |file|
      file << "# PCRE2 resource-limit tests: the pattern sets its own (*LIMIT_MATCH=...), (*LIMIT_DEPTH=...) or (*LIMIT_HEAP=...) and PCRE2 gives up there; spec/regex/bail_early_spec.cr covers them.\n"
      file << "# id<TAB>reason<TAB>approval (`approved by @login`, a code owner of /conformance/regex/)\n"
      rows.each do |row|
        next unless row.category == "resource-limit"
        approval = previous[row.id]?.try(&.approval) || ConformanceApproval::PENDING
        file << row.id << '\t' << row.reason << '\t' << approval << '\n'
      end
    end
  end
end

describe "Mica::Regex search conformance: PCRE2 testdata (valid UTF-8)" do
  it_satisfies "REGEX-R3-conformance", "gives PCRE2's result for every eligible subject on every engine path" do
    rows = PCRE2SearchReplay.classify(PCRE2SearchCorpus.load_verdicts)
    PCRE2SearchReplay.write_lists(rows) if ENV["MICA_REGEX_CONFORMANCE_WRITE"]? == "1"

    failures = rows.select(&.category.==("failed"))
    failures.first(10).map { |row| "#{row.id} #{row.pattern.inspect}: #{row.reason}" }.should eq([] of String)

    excluded = SearchConformance.read_list(File.join(PCRE2SearchReplay::DIRECTORY, "search_excluded.tsv"))
    divergent = SearchConformance.read_list(File.join(PCRE2SearchReplay::DIRECTORY, "search_divergences.tsv"))
    computed_excluded = rows.select(&.category.==("excluded")).map(&.id).to_set
    computed_divergent = rows.select(&.category.==("divergent")).map(&.id).to_set
    (computed_excluded ^ excluded.keys.to_set).should be_empty
    (computed_divergent ^ divergent.keys.to_set).should be_empty
    resource_limited = SearchConformance.read_list(PCRE2SearchReplay::RESOURCE_LIMITS_PATH)
    computed_resource_limited = rows.select(&.category.==("resource-limit")).map(&.id).to_set
    (computed_resource_limited ^ resource_limited.keys.to_set).should be_empty

    path = File.join(PCRE2SearchReplay::DIRECTORY, "search_denominator.json")
    denominator = PCRE2SearchReplay::Denominator.from_json(File.read(path))
    denominator.total.should eq(rows.size)
    denominator.excluded.should eq(computed_excluded.size)
    denominator.divergent.should eq(computed_divergent.size)
    denominator.resource_limited.should eq(computed_resource_limited.size)
    rows.count(&.category.==("passed")).should eq(denominator.eligible)

    {"search_divergences.tsv", "search_resource_limits.tsv"}.each do |list|
      rows_by_id = ConformanceApproval.read_rows(File.join(PCRE2SearchReplay::DIRECTORY, list))
      unapproved = ConformanceApproval.unapproved(rows_by_id)
      {list, unapproved.size, unapproved.first(10)}.should eq({list, 0, [] of String})
    end
  end
end
