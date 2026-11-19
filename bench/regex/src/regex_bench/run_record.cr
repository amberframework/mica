require "json"

module RegexBench
  # The machine, toolchain, corpus pins and settings of one run, written by
  # the driver as run.json and copied into the report.
  struct RunRecord
    include JSON::Serializable

    getter started_at : String
    getter finished_at : String = ""
    getter operating_system : String
    getter cpu : String
    getter logical_cpu_count : Int32
    getter memory_bytes : Int64
    getter crystal_version : String
    getter harness_commit : String
    getter mica_ref : String
    getter mica_commit : String
    getter rebar_commit : String
    getter rebar_tarball_sha256 : String
    getter list_of_corpora : Array(String)
    getter max_samples : Int32
    getter min_samples : Int32
    getter phase_seconds : Float64
    getter case_timeout_seconds : Float64
    getter redos_timeout_seconds : Float64
    getter engines : Array(EngineDescription)

    def initialize(*, @started_at, @operating_system, @cpu, @logical_cpu_count, @memory_bytes, @crystal_version,
                   @harness_commit, @mica_ref, @mica_commit, @rebar_commit, @rebar_tarball_sha256,
                   @list_of_corpora, @max_samples, @min_samples, @phase_seconds, @case_timeout_seconds,
                   @redos_timeout_seconds, @engines)
    end

    # Returns a copy stamped with the finish time.
    def finished(at time : Time) : self
      copy = dup
      copy.finished_at = time.to_rfc3339
      copy
    end

    protected setter finished_at : String
  end
end
