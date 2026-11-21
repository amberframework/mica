require "json"

module RegexBench
  # Loads the three case corpora and expands the Amber and ReDoS
  # definitions into one `BenchmarkCase` per size. The Amber and ReDoS
  # definitions and the rebar pin live in bench/regex/corpus; rebar's
  # converted definitions and haystacks live in the git-ignored data
  # directory, under rebar-<commit>/ (see scripts/rebar_corpus.rb).
  class Corpus
    LIST_OF_CORPORA = %w[rebar amber redos]

    struct RebarSource
      include JSON::Serializable

      getter repository : String
      getter commit : String
      getter tarball_sha256 : String
    end

    struct ExcludedCase
      include JSON::Serializable

      getter id : String
      getter reason : String
    end

    struct RebarDocument
      include JSON::Serializable

      getter source : RebarSource
      getter cases : Array(BenchmarkCase)
      getter excluded : Array(ExcludedCase) = [] of ExcludedCase
    end

    struct AmberPattern
      include JSON::Serializable

      getter generator : String
      getter name : String
      getter model : String
      getter pattern : String
      getter? case_insensitive : Bool = false
      getter source : String
      getter note : String = ""
    end

    struct AmberDocument
      include JSON::Serializable

      getter sizes : Array(Int64)
      getter patterns : Array(AmberPattern)
    end

    struct RedosFamily
      include JSON::Serializable

      getter name : String
      getter pattern : String
      getter prepend : String = ""
      getter unit : String
      getter append : String = ""
      getter source : String
    end

    struct RedosDocument
      include JSON::Serializable

      getter sizes : Array(Int64)
      getter deadline_ms : Int64
      getter families : Array(RedosFamily)
    end

    getter corpus_directory : String
    getter data_directory : String

    def initialize(@corpus_directory : String, @data_directory : String)
    end

    def rebar_pin : RebarSource
      RebarSource.from_json(read(File.join(@corpus_directory, "rebar_source.json")))
    end

    # The directory the rebar tarball was extracted into.
    def rebar_directory : String
      File.join(@data_directory, "rebar-#{rebar_pin.commit}")
    end

    def rebar_haystack_directory : String
      File.join(rebar_directory, "haystacks")
    end

    def rebar_document : RebarDocument
      RebarDocument.from_json(read(File.join(rebar_directory, "rebar.json")))
    end

    def rebar_cases : Array(BenchmarkCase)
      rebar_document.cases
    end

    def amber_cases : Array(BenchmarkCase)
      document = AmberDocument.from_json(read(File.join(@corpus_directory, "amber.json")))
      document.patterns.flat_map do |amber_pattern|
        document.sizes.map do |size|
          label = Corpus.size_label(size)
          BenchmarkCase.new(
            id: "amber/#{amber_pattern.generator}/#{amber_pattern.name}@#{label}",
            corpus: "amber",
            group: "amber/#{amber_pattern.generator}",
            subgroup: "amber/#{amber_pattern.generator}/#{amber_pattern.name}",
            model: amber_pattern.model,
            pattern: amber_pattern.pattern,
            case_insensitive: amber_pattern.case_insensitive?,
            haystack: HaystackSpec.new(generator: amber_pattern.generator, target_bytes: size),
            source: amber_pattern.source,
            note: amber_pattern.note,
            size_units: size)
        end
      end
    end

    def redos_document : RedosDocument
      RedosDocument.from_json(read(File.join(@corpus_directory, "redos.json")))
    end

    def redos_cases : Array(BenchmarkCase)
      document = redos_document
      document.families.flat_map do |family|
        document.sizes.map do |size|
          BenchmarkCase.new(
            id: "redos/#{family.name}@n=#{size}",
            corpus: "redos",
            group: "redos",
            subgroup: "redos/#{family.name}",
            model: "first-match",
            pattern: family.pattern,
            case_insensitive: false,
            haystack: HaystackSpec.new(contents: family.unit, repeat: size, prepend: family.prepend, append: family.append),
            source: family.source,
            family: family.name,
            size_units: size,
            deadline_ms: document.deadline_ms)
        end
      end
    end

    # Returns the cases of the named corpora, in corpus order.
    def cases_for(list_of_corpus_names : Array(String)) : Array(BenchmarkCase)
      list_of_corpus_names.flat_map do |corpus_name|
        case corpus_name
        when "rebar" then rebar_cases
        when "amber" then amber_cases
        when "redos" then redos_cases
        else
          raise CorpusError.new("unknown corpus #{corpus_name}; expected one of #{LIST_OF_CORPORA.join(", ")}")
        end
      end
    end

    # Formats a byte count as 1KiB, 64KiB, 1MiB, 100MiB.
    def self.size_label(bytes : Int64) : String
      if bytes >= 1_048_576 && bytes % 1_048_576 == 0
        "#{bytes // 1_048_576}MiB"
      elsif bytes >= 1024 && bytes % 1024 == 0
        "#{bytes // 1024}KiB"
      else
        "#{bytes}B"
      end
    end

    private def read(path : String) : String
      unless File.exists?(path)
        raise CorpusError.new("corpus file #{path} is missing; run /usr/bin/ruby bench/regex/scripts/rebar_corpus.rb")
      end
      File.read(path)
    end
  end
end
