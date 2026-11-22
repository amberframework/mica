# The differential fuzz harness for Mica::YAML, shared by
# spec/yaml/differential_spec.cr and fuzz/yaml_campaign.cr.
#
# Every case is one YAML input built from a seed and an iteration number,
# so it replays as SEED:ITERATION. Three generator families make the
# cases:
#
# - mutated: a seed document (the yaml-test-suite inputs when
#   MICA_YAML_SUITE points at them, plus the built-in configuration
#   samples) with `Mica::Testing::ByteMutator` mutations: YAML indicators
#   inserted, ranges deleted or duplicated, truncation, splices, hostile
#   bytes and re-encodings;
# - structured: a random document tree written out with random styles
#   (block and flow collections, every scalar style, anchors, aliases,
#   tags, comments, directives, several documents);
# - soup: indicators, words, blanks and line breaks in random order.
#
# A trial parses the case with Mica in the libyaml dialect and with
# libyaml (`YAMLOracle`), and compares: both accept with identical events
# (kinds, marks, anchors, tags, styles, implicit flags and scalar bytes),
# or both reject. It also parses the case in the YAML 1.2 dialect, where
# only crashes and budget overruns count.
require "../src/mica"
require "../src/mica/testing"
require "./yaml_oracle"
require "./yaml_events"

module YAMLFuzz
  # The generator families of the campaign summary.
  enum Family
    Mutated
    Structured
    Soup
  end

  # How one case compared.
  enum Verdict
    # Both parsers accepted and their events are identical.
    Agree
    # Both parsers rejected.
    BothReject
    # Both accepted with different events.
    Disagree
    # libyaml accepted, Mica rejected.
    OnlyMicaRejects
    # Mica accepted, libyaml rejected.
    OnlyOracleRejects
  end

  record Case, family : Family, bytes : Bytes

  # The outcome of one trial. *detail* describes the first difference
  # (empty when the verdict is Agree), *same_error* is true when both
  # rejected with the same message and marks, and *classification* names
  # the family of a rejection difference.
  record Trial, verdict : Verdict, detail : String, same_error : Bool, classification : String,
    operations : Int64, units : Int64, allowance : Int64, strict_outcome : String

  LIMITS = Mica::YAML::ParseLimits::LIBYAML

  INDICATORS = ["- ", "? ", ": ", ":", ",", "[", "]", "{", "}", "#", " #", "&a ", "*a", "!", "!!str ", "!<x> ", "|", ">",
                "|-", ">+", "|2", "'", "\"", "%YAML 1.2\n", "%TAG ! tag:x,2000:\n", "---", "--- ", "...", "\n", "\n\n",
                "\r\n", "\r", " ", "  ", "\t", "\\", "\\n", "\\x41", "\\u263A", "''", "<<", "~", "null", "true",
                "\u0085", "\u2028", "\u2029", "\uFEFF", "a", "key", "value", "0x1F", "1.5", "é", "\u{1F600}"]

  SAMPLES = [
    "name: mica\nversion: 0.2.0\nauthors:\n  - AgentC <agent_c@agentc.consulting>\ndependencies:\n  ameba:\n    github: crystal-ameba/ameba\n    commit: cdd58b3\nlicense: MIT\n",
    "default: &default\n  adapter: pg\n  pool: 5\n  timeout: 5000\ndevelopment:\n  <<: *default\n  database: app_dev\ntest:\n  <<: *default\n  database: app_test\n",
    "on:\n  push:\n    branches: [main]\n  pull_request:\njobs:\n  spec:\n    runs-on: ubuntu-24.04\n    steps:\n      - uses: actions/checkout@v6\n      - name: Run\n        run: |\n          crystal spec\n          echo done\n",
    "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: web\n  labels: {app: web, tier: \"front\"}\nspec:\n  replicas: 3\n  template:\n    spec:\n      containers:\n        - name: web\n          image: 'nginx:1.27'\n          args: [\"--port\", \"80\"]\n",
    "--- !!map\n? a\n: b\n--- >-\n  folded\n  text\n\n  more\n...\n%YAML 1.1\n---\n- &x [1, 2]\n- *x\n- \"esc \\t \\u00e9 \\\n  cont\"\n- 'it''s'\n",
    "{a: [b, {c: d}], \"e\": 'f', g: !!str h, ? i : j}\n",
    "- plain\n  multi line\n- |+\n  keep\n\n- >2\n   indented\n  fold\n# comment\n- key: value # trailing\n  other:   spaced\n",
  ].map(&.to_slice)

  # Returns the seed documents: the built-in samples, and every `in.yaml`
  # under *suite_directory* (the directory conformance/yaml/fetch_suite.rb
  # fills, or its data/ directory) when given.
  def self.list_of_seeds(suite_directory : String? = ENV["MICA_YAML_SUITE"]?) : Array(Bytes)
    list_of_seeds = SAMPLES.dup
    if suite_directory
      Dir.glob(File.join(suite_directory, "**/in.yaml")).sort!.each do |path|
        # The suite's name/ and tags/ directories are links to the same files.
        relative = path.lchop(suite_directory).lchop('/').lchop("data/")
        next unless relative[0, 4].matches?(/\A[A-Z0-9]{4}\z/) && relative[4]? == '/'
        list_of_seeds << File.read(path).to_slice
      end
    end
    list_of_seeds
  end

  def self.mutator(list_of_seeds : Array(Bytes)) : Mica::Testing::ByteMutator
    Mica::Testing::ByteMutator.new(list_of_seeds: list_of_seeds, list_of_tokens: INDICATORS.map(&.to_slice))
  end

  def self.random_for(seed : Int64, iteration : Int32) : Random::PCG32
    Random::PCG32.new((seed.to_u64 &* 0x9E3779B97F4A7C15_u64) ^ iteration.to_u64, 54_u64)
  end

  # Returns case *iteration* under *seed*.
  def self.case_for(mutator : Mica::Testing::ByteMutator, seed : Int64, iteration : Int32) : Case
    random = random_for(seed, iteration)
    choice = random.rand(10)
    if choice < 6
      Case.new(Family::Mutated, mutator.case_bytes(seed, iteration))
    elsif choice < 9
      bytes = structured(random)
      # A third of the structured cases get one mutation, to probe the
      # edges of valid documents.
      bytes = mutator.mutate(bytes, random) if random.rand(3) == 0
      Case.new(Family::Structured, bytes)
    else
      Case.new(Family::Soup, soup(random))
    end
  end

  # --- Generators -----------------------------------------------------------

  WORDS = ["a", "b", "key", "value", "x y", "1", "-1", "0.5", "true", "null", "~", "", "a:b", "a#b", "-x", "?x", ":x",
           "é", "日本", "it's", "say \"hi\"", "tab\there", "back\\slash", " lead", "trail ", "multi\nline",
           "two\n\nparas", "# not comment", "- not entry", "k: v", "[x]", "{x}", "a, b", "&x", "*x", "!x", "|", ">",
           "%x", "@x", "`x", "---", "...", "\u0085", "\u2028", "long " * 30]

  private def self.soup(random : Random) : Bytes
    String.build do |io|
      random.rand(1..40).times do
        io << (random.rand(3) == 0 ? WORDS.sample(random) : INDICATORS.sample(random))
      end
    end.to_slice.dup
  end

  private def self.structured(random : Random) : Bytes
    String.build do |io|
      documents = random.rand(8) == 0 ? random.rand(2..3) : 1
      documents.times do |index|
        io << "%YAML 1.#{random.rand(1..2)}\n" if random.rand(12) == 0
        io << "%TAG !e! tag:example.com,2000:\n" if random.rand(15) == 0
        io << "---" << (random.rand(2) == 0 ? "\n" : " ") if index > 0 || random.rand(3) == 0
        write_node(io, random, 0, random.rand(1..5), false, true)
        io << "\n" unless random.rand(20) == 0
        io << "...\n" if random.rand(8) == 0
      end
    end.to_slice.dup
  end

  private def self.write_properties(io : IO, random : Random) : Nil
    io << "&" << {"a", "b", "anchor-1"}.sample(random) << ' ' if random.rand(12) == 0
    io << {"!!str", "!!map", "!!seq", "!local", "!", "!<tag:x,2000:y>"}.sample(random) << ' ' if random.rand(15) == 0
  end

  # Writes one node. *indent* is the column block content must pass,
  # *budget* the remaining depth, *in_flow* whether a flow collection
  # surrounds it and *at_line_start* whether the node starts its line.
  private def self.write_node(io : IO, random : Random, indent : Int32, budget : Int32, in_flow : Bool,
                              at_line_start : Bool) : Nil
    write_properties(io, random)
    choice = budget <= 0 ? 0 : random.rand(10)
    if choice < 4
      write_scalar(io, random, indent, in_flow)
    elsif in_flow || choice == 4 || choice == 5
      write_flow(io, random, indent, budget - 1)
    elsif choice < 8
      count = random.rand(1..4)
      count.times do |index|
        io << '\n' << " " * indent if index > 0 || !at_line_start
        if random.rand(15) == 0
          io << "? "
          write_node(io, random, indent + 2, budget - 1, false, true)
          io << '\n' << " " * indent << ": "
        else
          write_key(io, random)
          io << ':' << (random.rand(10) == 0 ? "  " : " ")
        end
        io << "# note" if random.rand(25) == 0
        write_node(io, random, indent + 2, budget - 1, false, false)
      end
    else
      count = random.rand(1..4)
      count.times do |index|
        io << '\n' << " " * indent if index > 0 || !at_line_start
        io << "- "
        write_node(io, random, indent + 2, budget - 1, false, true)
      end
    end
  end

  private def self.write_key(io : IO, random : Random) : Nil
    case random.rand(8)
    when 0 then io << '"' << WORDS.sample(random).gsub('\\', "\\\\").gsub('"', "\\\"").gsub('\n', "\\n") << '"'
    when 1 then io << '\'' << WORDS.sample(random).gsub('\'', "''").gsub('\n', " ") << '\''
    when 2 then io << "*a"
    else        io << {"a", "b", "key", "k2", "long key", "x-y", "1", "<<", "é"}.sample(random)
    end
  end

  private def self.write_flow(io : IO, random : Random, indent : Int32, budget : Int32) : Nil
    mapping = random.rand(2) == 0
    io << (mapping ? '{' : '[')
    random.rand(0..4).times do |index|
      io << ',' << (random.rand(8) == 0 ? "\n" + " " * (indent + 1) : " ") if index > 0
      if mapping
        write_key(io, random)
        io << (random.rand(10) == 0 ? ":" : ": ")
      end
      write_node(io, random, indent + 1, budget - 1, true, false)
    end
    io << ',' if random.rand(15) == 0
    io << (mapping ? '}' : ']')
  end

  private def self.write_scalar(io : IO, random : Random, indent : Int32, in_flow : Bool) : Nil
    word = WORDS.sample(random)
    case random.rand(in_flow ? 6 : 9)
    when 0
      io << '"' << word.gsub('\\', "\\\\").gsub('"', "\\\"").gsub('\n', "\\n").gsub('\t', "\\t") << '"'
    when 1
      io << '\'' << word.gsub('\'', "''").gsub('\n', "\n\n" + " " * (indent + 1)) << '\''
    when 2
      io << "*a"
    when 3, 4, 5
      io << word.gsub('\n', "\n" + " " * (indent + 1))
    when 6, 7
      io << (random.rand(2) == 0 ? '|' : '>') << {"", "-", "+", "2", "1-", "+2"}.sample(random)
      io << " # c" if random.rand(20) == 0
      random.rand(1..4).times do
        io << '\n' << " " * (indent + random.rand(1..3)) << WORDS.sample(random).gsub('\n', "\n" + " " * (indent + 2))
        io << '\n' if random.rand(5) == 0
      end
    else
      io << "\"" << word.gsub('\\', "\\\\").gsub('"', "\\\"").gsub('\n', "\\\n" + " " * (indent + 1)) << '"'
    end
  end

  # --- Trials -----------------------------------------------------------------

  def self.describe(parser : Mica::YAML::PullParser) : Array(String)
    YAMLEvents.describe(parser)
  end

  def self.describe_error(error : Mica::Error) : String
    YAMLEvents.describe_error(error)
  end

  # Parses *bytes* with Mica in *dialect*; returns the events or the
  # error, and the work done.
  def self.parse_with_mica(bytes : Bytes, dialect : Mica::YAML::Dialect,
                           limits : Mica::YAML::ParseLimits = LIMITS) : {Array(String), Mica::Error?, Mica::Core::WorkMeter}
    meter = Mica::Core::WorkMeter.new(limits.work_budget(nil))
    list_of_events = [] of String
    begin
      parser = Mica::YAML::PullParser.new(bytes, limits: limits, timeout: nil, dialect: dialect, meter: meter)
      list_of_events = describe(parser)
      {list_of_events, nil, meter}
    rescue error : Mica::Error
      {list_of_events, error, meter}
    end
  end

  # Runs one case through both parsers and compares.
  def self.trial(bytes : Bytes) : Trial
    oracle = YAMLOracle.parse(bytes)
    list_of_events, error, meter = parse_with_mica(bytes, Mica::YAML::Dialect::LibYAML)
    strict_events, strict_error, _ = parse_with_mica(bytes, Mica::YAML::Dialect::YAML12, Mica::YAML::ParseLimits::TRUSTED_FILE)
    strict_outcome = strict_error ? "reject" : "accept #{strict_events.size}"
    verdict = Verdict::Agree
    detail = ""
    same_error = false
    classification = ""
    oracle_error = oracle.error
    if error && oracle_error
      verdict = Verdict::BothReject
      mica_text = describe_error(error)
      same_error = mica_text == oracle_error || (oracle.error_kind == 2 && error.is_a?(Mica::YAML::InvalidCharacterError))
      detail = "mica: #{mica_text} | libyaml: #{oracle_error}" unless same_error
    elsif error
      verdict = Verdict::OnlyMicaRejects
      classification = "mica rejects: #{error.class.name}: #{error.is_a?(Mica::ParseError) ? error.detail : error.message}"
      detail = "mica: #{describe_error(error)}"
    elsif oracle_error
      verdict = Verdict::OnlyOracleRejects
      classification = "libyaml rejects: #{oracle_error.partition(" at ")[0]}"
      detail = "libyaml: #{oracle_error}"
    elsif list_of_events != oracle.list_of_events
      verdict = Verdict::Disagree
      index = 0
      while index < list_of_events.size && index < oracle.list_of_events.size && list_of_events[index] == oracle.list_of_events[index]
        index += 1
      end
      detail = "event #{index}: mica #{list_of_events[index]?.inspect} | libyaml #{oracle.list_of_events[index]?.inspect}"
    end
    Trial.new(verdict, detail, same_error, classification, meter.operations, meter.units, meter.allowance, strict_outcome)
  end
end
