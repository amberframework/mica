# The GC-free study's measurement program (docs/benchmarks.md, "GC-free
# study"): for every corpus case, the heap allocations of a compile, of a
# process's first search and of a warm search on today's runtime engine,
# the time the collector takes from a warm workload, and the shape of the
# pattern's tables (NFA states, byte classes, groups, and the complete
# forward and reverse DFAs `Mica::Regex.static` would build).
#
#   crystal-alpha build --release bench/regex/gc_study/measure_allocations.cr -o bench/bin/regex/measure_allocations
#   bench/bin/regex/measure_allocations --out FILE.jsonl [--corpora rebar,amber,redos] [--max-amber-bytes N]
#
# It counts allocations by wrapping the collector's three entry points in
# this program only (every Crystal heap allocation goes through them), so
# the library itself is measured unchanged.
require "option_parser"
require "../../../src/mica"
require "../../../src/mica/regex/static/build_the_tables"
require "../src/regex_bench"
require "../src/regex_bench/engines/mica_engine"

lib LibGC
  fun start_performance_measurement = GC_start_performance_measurement : Void
  fun get_full_gc_total_time = GC_get_full_gc_total_time : LibC::ULong
end

# Counts heap allocations (calls and bytes) since the program started.
module AllocationCounter
  class_property count = 0_u64
  class_property bytes = 0_u64

  # Returns the count and bytes allocated while the block ran, and the
  # block's value.
  def self.measure(& : -> T) forall T
    count_before = count
    bytes_before = bytes
    value = yield
    {count - count_before, bytes - bytes_before, value}
  end
end

module GC
  def self.malloc(size : LibC::SizeT) : Void*
    AllocationCounter.count &+= 1
    AllocationCounter.bytes &+= size
    previous_def
  end

  def self.malloc_atomic(size : LibC::SizeT) : Void*
    AllocationCounter.count &+= 1
    AllocationCounter.bytes &+= size
    previous_def
  end

  def self.realloc(ptr : Void*, size : LibC::SizeT) : Void*
    AllocationCounter.count &+= 1
    AllocationCounter.bytes &+= size
    previous_def
  end
end

module GcStudy
  # Counts the finds a workload makes.
  class CountingPattern < RegexBench::CompiledPattern
    getter finds = 0_i64

    def initialize(@inner : RegexBench::CompiledPattern)
    end

    def find(haystack : String, byte_offset : Int32, first_search : Bool, count_groups : Bool) : RegexBench::Span?
      @finds += 1
      @inner.find(haystack, byte_offset, first_search, count_groups)
    end
  end

  # The shape of one direction's complete DFA.
  struct DirectionShape
    include JSON::Serializable

    getter states : Int32
    getter stride : Int32
    getter entry_bytes : Int32
    getter state_id_bytes : Int32
    getter accelerated_states : Int32

    def initialize(@states, @stride, @entry_bytes, @state_id_bytes, @accelerated_states)
    end
  end

  # What one case measured.
  struct CaseRecord
    include JSON::Serializable

    getter case_id : String
    getter corpus : String
    getter group : String
    getter model : String
    getter haystack_bytes : Int32
    getter status : String
    getter detail : String = ""
    getter nfa_states : Int32 = 0
    getter byte_classes : Int32 = 0
    getter capture_count : Int32 = 0
    getter slot_count : Int32 = 0
    getter static_status : String = ""
    getter static_reason : String = ""
    getter forward : DirectionShape? = nil
    getter reverse : DirectionShape? = nil
    getter nfa_index_bytes : Int32 = 0
    getter static_table_bytes : Int32 = 0
    getter static_scratch_bytes : Int32 = 0
    getter static_build_seconds : Float64 = 0.0
    getter compile_allocations : UInt64 = 0
    getter compile_bytes : UInt64 = 0
    getter first_search_allocations : UInt64 = 0
    getter first_search_bytes : UInt64 = 0
    getter early_finds : Int64 = 0
    getter early_allocations : UInt64 = 0
    getter early_bytes : UInt64 = 0
    getter warm_finds : Int64 = 0
    getter warm_allocations : UInt64 = 0
    getter warm_bytes : UInt64 = 0
    getter gc_runs : Int32 = 0
    getter gc_on_seconds : Float64 = 0.0
    getter gc_off_seconds : Float64 = 0.0
    getter gc_collections : UInt64 = 0
    getter gc_full_ms : UInt64 = 0

    def initialize(@case_id, @corpus, @group, @model, @haystack_bytes, @status, @detail = "")
    end

    def with_shape(@nfa_states, @byte_classes, @capture_count, @slot_count) : self
      self
    end

    def with_static(@static_status, @static_reason, @forward, @reverse, @nfa_index_bytes, @static_table_bytes,
                    @static_scratch_bytes, @static_build_seconds) : self
      self
    end

    def with_allocations(@compile_allocations, @compile_bytes, @first_search_allocations, @first_search_bytes,
                         @warm_finds, @warm_allocations, @warm_bytes) : self
      self
    end

    def with_early(@early_finds, @early_allocations, @early_bytes) : self
      self
    end

    def with_gc(@gc_runs, @gc_on_seconds, @gc_off_seconds, @gc_collections, @gc_full_ms) : self
      self
    end
  end

  # The static build of one pattern, kept per pattern.
  record StaticShape, status : String, reason : String, forward : DirectionShape?, reverse : DirectionShape?,
    nfa_index_bytes : Int32, table_bytes : Int32, scratch_bytes : Int32, seconds : Float64

  # When the study runs over the selected corpora, then each case is
  # compiled and searched on the runtime engine with the allocation
  # counter running, timed with the collector on and off, and its pattern's
  # static tables are built once, and one `CaseRecord` per case is written
  # as a JSON line.
  class MeasureTheCorpus
    GC_SECONDS      =  0.3
    WARM_UP_RUNS    =  200
    WARM_UP_SECONDS =  0.2
    MEASURE_SECONDS = 0.05

    def initialize(@corpus : RegexBench::Corpus, @list_of_corpora : Array(String), @max_amber_bytes : Int64,
                   @output : IO, @progress : IO)
      @engine = RegexBench.build_mica_engine
      @shapes = {} of {String, Bool} => StaticShape
    end

    def perform : Nil
      LibGC.start_performance_measurement
      list_of_cases = @corpus.cases_for(@list_of_corpora).select do |benchmark_case|
        benchmark_case.corpus != "amber" || benchmark_case.size_units <= @max_amber_bytes
      end
      list_of_cases.each_with_index do |benchmark_case, index|
        record = measure(benchmark_case)
        record.to_json(@output)
        @output.puts
        @output.flush
        @progress.puts "[#{index + 1}/#{list_of_cases.size}] #{benchmark_case.id} #{record.status} warm #{record.warm_allocations}/#{record.warm_finds}"
      end
    end

    private def measure(benchmark_case : RegexBench::BenchmarkCase) : CaseRecord
      haystack = RegexBench::HaystackBuilder.new(benchmark_case.haystack, @corpus.rebar_haystack_directory).build
      record = CaseRecord.new(benchmark_case.id, benchmark_case.corpus, benchmark_case.group, benchmark_case.model,
        haystack.bytesize, "ok")
      options = benchmark_case.case_insensitive? ? Mica::Regex::CompileOptions::IgnoreCase : Mica::Regex::CompileOptions::None
      expression = begin
        Mica::Regex.compile(benchmark_case.pattern, dialect: :crystal,
          compile_limits: Mica::Regex::CompileLimits::TRUSTED_PATTERN, options: options)
      rescue error : Mica::Regex::SyntaxError | Mica::Regex::CompileLimitError
        return CaseRecord.new(benchmark_case.id, benchmark_case.corpus, benchmark_case.group, benchmark_case.model,
          haystack.bytesize, "unsupported", error.message || "")
      end
      program = expression.program
      record = record.with_shape(program.state_count, Mica::Regex::ByteClasses.new(program).class_count,
        program.capture_count, program.slot_count)
      shape = static_shape(benchmark_case.pattern, options)
      record = record.with_static(shape.status, shape.reason, shape.forward, shape.reverse, shape.nfa_index_bytes,
        shape.table_bytes, shape.scratch_bytes, shape.seconds)
      measure_searches(benchmark_case, haystack, record)
    rescue error : RegexBench::UnsupportedCaseError
      CaseRecord.new(benchmark_case.id, benchmark_case.corpus, benchmark_case.group, benchmark_case.model,
        0, "unsupported", error.message || "")
    rescue error : RegexBench::LimitReachedError | Mica::LimitExceededError
      CaseRecord.new(benchmark_case.id, benchmark_case.corpus, benchmark_case.group, benchmark_case.model,
        0, "limit", error.message || "")
    end

    private def measure_searches(benchmark_case : RegexBench::BenchmarkCase, haystack : String,
                                 record : CaseRecord) : CaseRecord
      policy = RegexBench::SearchPolicy.new(deadline: benchmark_case.deadline,
        untrusted_input: benchmark_case.belongs_to_the_redos_set?)
      # The compile the harness's samples measure: a process that has
      # compiled before (shared class tables built).
      @engine.compile(benchmark_case.pattern, benchmark_case.case_insensitive?, policy)
      compile_count, compile_bytes, compiled = AllocationCounter.measure do
        @engine.compile(benchmark_case.pattern, benchmark_case.case_insensitive?, policy)
      end
      first_count, first_bytes, _ = AllocationCounter.measure { compiled.find(haystack, 0, true, false) }
      counting = CountingPattern.new(compiled)
      workload = RegexBench::Workload.new(counting, haystack, benchmark_case.model)
      started = Time.instant
      workload.run
      one_run = (Time.instant - started).total_seconds
      # The runs while the engine adapts (its first searches build the
      # plan, caches and filters), then the steady state after
      # `WARM_UP_RUNS` runs or `WARM_UP_SECONDS`.
      early_finds = counting.finds
      early_count, early_bytes, _ = AllocationCounter.measure { 2.times { workload.run } }
      early_finds = counting.finds - early_finds
      record = record.with_early(early_finds, early_count, early_bytes)
      return record.with_allocations(compile_count, compile_bytes, first_count, first_bytes, early_finds,
        early_count, early_bytes) if one_run > 0.5
      warm_up_started = Time.instant
      WARM_UP_RUNS.times do
        break if (Time.instant - warm_up_started).total_seconds > WARM_UP_SECONDS
        workload.run
      end
      measured_runs = (MEASURE_SECONDS / Math.max(one_run, 1e-7)).to_i.clamp(1, 1_000)
      finds_before = counting.finds
      warm_count, warm_bytes, _ = AllocationCounter.measure { measured_runs.times { workload.run } }
      record = record.with_allocations(compile_count, compile_bytes, first_count, first_bytes,
        counting.finds - finds_before, warm_count, warm_bytes)
      runs = Math.max(1, (GC_SECONDS / Math.max(one_run, 1e-7)).to_i)
      runs = Math.min(runs, 1_000_000)
      on_seconds = off_seconds = 0.0
      collections = 0_u64
      full_ms = 0_u64
      # Paired and interleaved: collector on, then off, three times.
      3.times do
        gc_before = GC.prof_stats.gc_no
        ms_before = LibGC.get_full_gc_total_time
        started = Time.instant
        runs.times { workload.run }
        on_seconds += (Time.instant - started).total_seconds
        collections += GC.prof_stats.gc_no - gc_before
        full_ms += LibGC.get_full_gc_total_time - ms_before
        GC.collect
        GC.disable
        started = Time.instant
        runs.times { workload.run }
        off_seconds += (Time.instant - started).total_seconds
        GC.enable
        GC.collect
      end
      record.with_gc(runs * 3, on_seconds, off_seconds, collections, full_ms)
    end

    private def static_shape(pattern : String, options : Mica::Regex::CompileOptions) : StaticShape
      key = {pattern, options.ignore_case?}
      if found = @shapes[key]?
        return found
      end
      started = Time.instant
      result = Mica::Regex::Static::BuildTheTables.new(pattern, options).perform
      seconds = (Time.instant - started).total_seconds
      shape = if result.is_a?(Mica::Regex::Static::Refusal)
                StaticShape.new("fallback", result.reason, nil, nil, 0, 0, 0, seconds)
              else
                forward = shape_of(result.forward)
                reverse = shape_of(result.reverse)
                nfa = result.nfa
                nfa_bytes = 0
                if nfa
                  largest = {nfa.list_of_next_states, nfa.list_of_alternates, nfa.list_of_arguments, nfa.list_of_sparse_targets}.max_of { |list| list.max? || 0 }
                  nfa_bytes = Mica::Regex::Static::BuildTheTables.width_of(largest)
                end
                table_bytes = 256 + forward.states * forward.stride * forward.entry_bytes +
                              reverse.states * reverse.stride * reverse.entry_bytes
                scratch = result.nfa ? result.scratch_words * 4 : 0
                StaticShape.new("static", "", forward, reverse, nfa_bytes, table_bytes, scratch, seconds)
              end
      @shapes[key] = shape
    end

    private def shape_of(tables : Mica::Regex::Static::DirectionTables) : DirectionShape
      DirectionShape.new(tables.state_count, tables.stride,
        Mica::Regex::Static::BuildTheTables.width_of(tables.largest_entry),
        Mica::Regex::Static::BuildTheTables.width_of(tables.state_count - 1),
        tables.list_of_accel_bytes.size)
    end
  end
end

output_path = ""
list_of_corpora = %w[rebar amber redos]
max_amber_bytes = 1_048_576_i64
OptionParser.parse do |parser|
  parser.on("--out FILE", "JSON lines output") { |value| output_path = value }
  parser.on("--corpora LIST", "Comma-separated corpora") { |value| list_of_corpora = value.split(',') }
  parser.on("--max-amber-bytes N", "Skip larger Amber haystacks") { |value| max_amber_bytes = value.to_i64 }
end
abort "--out FILE is required" if output_path.empty?
corpus = RegexBench::Corpus.new(File.expand_path("../corpus", __DIR__), File.expand_path("../../data/regex", __DIR__))
File.open(output_path, "w") do |file|
  GcStudy::MeasureTheCorpus.new(corpus, list_of_corpora, max_amber_bytes, file, STDERR).perform
end
