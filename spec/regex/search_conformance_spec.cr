require "../spec_helper"
require "./support/search_corpus"
require "./support/conformance_approval"

# The search conformance gate of milestone R2 (roadmap 6.5): the RE2
# search tests and the Rust regex TOML tests, each pinned by commit and
# sha256, with a fixed denominator. Every case lands in exactly one list:
#
# - **excluded** (conformance/regex/<corpus>/excluded.tsv): outside the
#   Crystal dialect's search semantics (leftmost-longest columns, regex
#   sets, byte-oriented and ASCII-only modes, invalid UTF-8 until R4, an end
#   bound), a construct the dialect leaves out, a pattern both Mica and
#   PCRE2 reject, or a compile limit;
# - **divergent** (divergences.tsv): the corpus engine expects something
#   else, and PCRE2 10.49 (spec/regex/fixtures/pcre2_search_verdicts.json)
#   gives exactly Mica's result, so the difference is the Crystal dialect's
#   meaning, not a Mica defect;
# - **eligible**: every other case, and every eligible case must pass, on
#   every engine path that applies: the default path (literal search,
#   prefilter, lazy DFAs, one-pass DFA), the same without the literal
#   accelerators, R2's two phases, the Pike VM, and the backtracker.
#
# Every divergence row must name its approver, a code owner of
# /conformance/regex/ (see `ConformanceApproval`); an unapproved row fails
# the gate.
#
# The lists must partition the corpus and match the files exactly; the
# eligible count is pinned in denominator.json. Set
# MICA_REGEX_CONFORMANCE_WRITE=1 to rewrite the files from a run (a change
# then shows in review); a rewrite keeps the approval of every row that
# stays and marks a new row pending.
module SearchConformance
  record Classified, id : String, pattern : String, category : String, reason : String

  ENGINES = [Mica::Regex::Engine::Auto, Mica::Regex::Engine::NoAccelerators, Mica::Regex::Engine::TwoPhase,
             Mica::Regex::Engine::PikeVM, Mica::Regex::Engine::Backtracker, Mica::Regex::Engine::EachStart]

  def self.classify(corpus : SearchCorpus::Corpus, verdicts : Hash(String, SearchCorpus::Outcome)) : Array(Classified)
    SearchCorpus.scoped(corpus).map do |id, pattern, scoped|
      job = scoped.job
      next Classified.new(id, pattern, "excluded", scoped.exclusion || "") unless job
      classify_job(id, pattern, job, verdicts[id]?)
    end
  end

  def self.classify_job(id : String, pattern : String, job : SearchCorpus::Job,
                        verdict : SearchCorpus::Outcome?) : Classified
    mica = SearchCorpus.run_mica(job)
    unless mica.compiled?
      case mica.error_kind
      when "unsupported"
        return Classified.new(id, pattern, "excluded", "excluded construct: #{mica.error}")
      when "limit"
        return Classified.new(id, pattern, "excluded", "refused by the compile limit #{mica.error}")
      else
        if verdict && !verdict.compiled? && job.expected.compiled?
          return Classified.new(id, pattern, "excluded", "outside the Crystal dialect: PCRE2 rejects it too (#{verdict.error})")
        end
      end
    end
    if job.expected.same_result?(mica, job.groups_compared)
      mismatch = engine_mismatch(job, mica)
      return Classified.new(id, pattern, "failed", mismatch) if mismatch
      return Classified.new(id, pattern, "passed", "")
    end
    if verdict && verdict.same_result?(mica)
      return Classified.new(id, pattern, "divergent", divergence_reason(job, mica))
    end
    detail = "expected #{job.expected.describe}, Mica gives #{mica.describe}"
    detail += ", PCRE2 gives #{verdict.describe}" if verdict
    Classified.new(id, pattern, "failed", detail)
  end

  # Runs the other engine paths and returns how one disagrees, or nil.
  def self.engine_mismatch(job : SearchCorpus::Job, mica : SearchCorpus::Outcome) : String?
    return nil unless mica.compiled?
    expression = Mica::Regex::Expression.new(job.pattern, job.compile_options,
      compile_limits: Mica::Regex::CompileLimits::TRUSTED_PATTERN)
    ENGINES.each do |engine|
      next if engine.auto?
      next unless SearchCorpus.engine_applies?(job, expression.program, engine)
      other = SearchCorpus.run_mica(job, engine)
      # A path that runs out of its work allowance gives no answer to compare.
      next if other.error_kind == "search-limit"
      return "#{engine} gives #{other.describe}, the default path gives #{mica.describe}" unless other.same_result?(mica)
    end
    nil
  end

  # A divergence's reason: the kind of difference, then what the corpus
  # engine expects and what the Crystal dialect (PCRE2 and Mica) gives.
  def self.divergence_reason(job : SearchCorpus::Job, mica : SearchCorpus::Outcome) : String
    "#{divergence_kind(job, mica)}. PCRE2 10.49 and Mica give #{mica.describe}; the corpus engine expects #{job.expected.describe}"
  end

  def self.divergence_kind(job : SearchCorpus::Job, mica : SearchCorpus::Outcome) : String
    expected = job.expected
    return "The Crystal dialect accepts this pattern" unless expected.compiled?
    return "Rust's \\b{start}/\\b{end} syntax; PCRE2 reads \\b followed by literal text" if job.pattern.includes?("\\b{")
    return "regex-lite is ASCII-only; the Crystal dialect is Unicode-aware (UCP)" if job.id.starts_with?("regex-lite.toml")
    expected_spans = expected.matches.map(&.first)
    mica_spans = mica.matches.map(&.first)
    extra = mica_spans - expected_spans
    if (expected_spans - mica_spans).empty? && !extra.empty? && extra.all? { |span| span && span[0] == span[1] }
      return "Iteration: Crystal's String#scan reports an empty match that starts where the previous match ended; Rust regex skips it"
    end
    if expected_spans == mica_spans
      return "Captures: PCRE2 ends a group repetition after an iteration that matched the empty string and keeps that iteration's captures"
    end
    if job.pattern.includes?("(?m)") && job.haystack.ends_with?('\n')
      return "Multiline ^ does not match after a newline that ends the haystack in PCRE2"
    end
    "The Crystal dialect's meaning differs"
  end

  def self.read_list(path : String) : Hash(String, String)
    list = {} of String => String
    return list unless File.exists?(path)
    File.each_line(path) do |line|
      next if line.starts_with?('#') || line.blank?
      fields = line.split('\t')
      list[fields[0]] = fields[1]? || ""
    end
    list
  end

  struct Denominator
    include JSON::Serializable

    getter total : Int32
    getter excluded : Int32
    getter divergent : Int32
    getter eligible : Int32

    def initialize(@total : Int32, @excluded : Int32, @divergent : Int32, @eligible : Int32)
    end
  end

  def self.write_lists(corpus : SearchCorpus::Corpus, rows : Array(Classified)) : Nil
    directory = corpus.directory
    File.open(File.join(directory, "excluded.tsv"), "w") do |file|
      file << "# Cases outside the Crystal dialect's search semantics (roadmap 6.5). id<TAB>reason\n"
      rows.each { |row| file << row.id << '\t' << row.reason << '\n' if row.category == "excluded" }
    end
    divergences_path = File.join(directory, "divergences.tsv")
    previous = ConformanceApproval.read_rows(divergences_path)
    File.open(divergences_path, "w") do |file|
      file << "# Approved divergences: the corpus engine expects another result and PCRE2 10.49 gives Mica's.\n"
      file << "# id<TAB>reason<TAB>approval (`approved by @login`, a code owner of /conformance/regex/)\n"
      rows.each do |row|
        next unless row.category == "divergent"
        approval = previous[row.id]?.try(&.approval) || ConformanceApproval::PENDING
        file << row.id << '\t' << row.reason << '\t' << approval << '\n'
      end
    end
    counts = Denominator.new(rows.size, rows.count(&.category.==("excluded")), rows.count(&.category.==("divergent")),
      rows.count { |row| row.category == "passed" || row.category == "failed" })
    File.write(File.join(directory, "denominator.json"), counts.to_pretty_json + "\n")
  end
end

{SearchCorpus::Corpus::RE2, SearchCorpus::Corpus::Rust}.each do |corpus|
  describe "Mica::Regex search conformance: #{corpus}" do
    it_satisfies "REGEX-R2-conformance", "passes every eligible case of the pinned corpus with a fixed denominator" do
      verdicts = SearchCorpus.load_verdicts
      rows = SearchConformance.classify(corpus, verdicts)
      SearchConformance.write_lists(corpus, rows) if ENV["MICA_REGEX_CONFORMANCE_WRITE"]? == "1"

      failures = rows.select(&.category.==("failed"))
      failures.first(10).map { |row| "#{row.id} #{row.pattern.inspect}: #{row.reason}" }.should eq([] of String)

      excluded = SearchConformance.read_list(File.join(corpus.directory, "excluded.tsv"))
      divergent = SearchConformance.read_list(File.join(corpus.directory, "divergences.tsv"))
      computed_excluded = rows.select(&.category.==("excluded")).map(&.id).to_set
      computed_divergent = rows.select(&.category.==("divergent")).map(&.id).to_set
      (computed_excluded ^ excluded.keys.to_set).should be_empty
      (computed_divergent ^ divergent.keys.to_set).should be_empty
      (excluded.keys.to_set & divergent.keys.to_set).should be_empty

      denominator = SearchConformance::Denominator.from_json(File.read(File.join(corpus.directory, "denominator.json")))
      denominator.total.should eq(rows.size)
      denominator.excluded.should eq(computed_excluded.size)
      denominator.divergent.should eq(computed_divergent.size)
      eligible = rows.count(&.category.==("passed"))
      (denominator.excluded + denominator.divergent + eligible).should eq(rows.size)
      eligible.should eq(denominator.eligible)

      rows_by_id = ConformanceApproval.read_rows(File.join(corpus.directory, "divergences.tsv"))
      unapproved = ConformanceApproval.unapproved(rows_by_id)
      {unapproved.size, unapproved.first(10)}.should eq({0, [] of String})
    end
  end
end
