# One engine of the YAML benchmark: parses one file again and again and
# prints how fast.
#
#   runner ENGINE FILE MIN_SECONDS
#
# prints `ENGINE<TAB>bytes<TAB>iterations<TAB>seconds<TAB>checksum`. The
# checksum (events and scalar bytes seen in one pass, or values built)
# lets the driver confirm that engines compared with each other did the
# same work.
#
# Engines:
#
# - mica-events: `Mica::YAML::PullParser` (YAML 1.2 dialect), every event
#   read and every scalar's value taken;
# - mica-events-libyaml-dialect: the same in the libyaml dialect;
# - mica-parse: `Mica::YAML.parse_all` (values under the core schema);
# - stdlib-events: the standard library's `YAML::PullParser`, every event
#   read and every scalar's value taken;
# - stdlib-parse: the standard library's `YAML.parse_all`;
# - stdlib-emit: the standard library's `to_yaml` of every document of the
#   file (parsed once, before the clock starts), which writes through
#   `YAML::Builder`.
#
# The stdlib engines run on libyaml in a default build. Built with
# `-Dyaml_stdlib_only -Duse_mica` against the crystal-alpha fork's
# standard library (bench/yaml/run.sh does this when CRYSTAL_MICA_STDLIB
# is set), the same two engines run on Mica through the compatibility
# layer, and the binary links no libyaml.
require "yaml"
{% unless flag?(:yaml_stdlib_only) %}
  require "../../src/mica"
{% end %}

module YAMLBench
  {% unless flag?(:yaml_stdlib_only) %}
    LIMITS = Mica::YAML::ParseLimits::TRUSTED_FILE

    def self.mica_events(data : String, dialect : Mica::YAML::Dialect) : Int64
      parser = Mica::YAML::PullParser.new(data, limits: LIMITS, timeout: nil, dialect: dialect)
      checksum = 0_i64
      until parser.kind.stream_end?
        checksum += 1
        checksum += parser.value.bytesize if parser.kind.scalar?
        parser.read_next
      end
      checksum
    end

    def self.mica_parse(data : String) : Int64
      Mica::YAML.parse_all(data, limits: LIMITS, timeout: nil).size.to_i64
    end
  {% end %}

  def self.stdlib_events(data : String) : Int64
    parser = YAML::PullParser.new(data)
    checksum = 0_i64
    until parser.kind.stream_end?
      checksum += 1
      checksum += parser.value.bytesize if parser.kind.scalar?
      parser.read_next
    end
    parser.close
    checksum
  end

  def self.stdlib_parse(data : String) : Int64
    YAML.parse_all(data).size.to_i64
  end

  class_getter list_of_documents = [] of YAML::Any

  def self.stdlib_emit : Int64
    bytes = 0_i64
    list_of_documents.each { |document| bytes += document.to_yaml.bytesize }
    bytes
  end

  def self.run(engine : String, data : String) : Int64
    case engine
    when "stdlib-emit"   then stdlib_emit
    when "stdlib-events" then stdlib_events(data)
    when "stdlib-parse"  then stdlib_parse(data)
    else                      run_mica(engine, data)
    end
  end

  {% if flag?(:yaml_stdlib_only) %}
    def self.run_mica(engine : String, data : String) : Int64
      abort "unknown engine #{engine}"
    end
  {% else %}
    def self.run_mica(engine : String, data : String) : Int64
      case engine
      when "mica-events"                 then mica_events(data, Mica::YAML::Dialect::YAML12)
      when "mica-events-libyaml-dialect" then mica_events(data, Mica::YAML::Dialect::LibYAML)
      when "mica-parse"                  then mica_parse(data)
      else                                    abort "unknown engine #{engine}"
      end
    end
  {% end %}
end

usage = "usage: runner ENGINE FILE MIN_SECONDS"
engine = ARGV[0]? || abort(usage)
data = File.read(ARGV[1]? || abort(usage))
min_seconds = (ARGV[2]? || abort(usage)).to_f

YAMLBench.list_of_documents.concat(YAML.parse_all(data)) if engine == "stdlib-emit"
checksum = YAMLBench.run(engine, data)
# Warm up, then double the batch until one batch fills the window.
iterations = 1
elapsed = 0.0
loop do
  started = Time.instant
  iterations.times { YAMLBench.run(engine, data) }
  elapsed = (Time.instant - started).total_seconds
  break if elapsed >= min_seconds
  iterations *= elapsed < min_seconds / 16 ? 8 : 2
end
STDOUT << engine << '\t' << data.bytesize << '\t' << iterations << '\t' << elapsed << '\t' << checksum << '\n'
