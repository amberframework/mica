require "../spec_helper"
require "../../fuzz/yaml_events"

YAML_LIMITS = Mica::YAML::ParseLimits::CONFIG_FILE

# Returns the events of *source* as short strings: the kind, then the
# anchor, tag and scalar text when present.
def yaml_events(source : String | Bytes | IO, dialect : Mica::YAML::Dialect = Mica::YAML::Dialect::YAML12,
                limits : Mica::YAML::ParseLimits = YAML_LIMITS) : Array(String)
  parser = Mica::YAML::PullParser.new(source, limits: limits, timeout: nil, dialect: dialect)
  list_of_events = [] of String
  loop do
    list_of_events << String.build do |io|
      io << parser.kind
      if anchor = parser.anchor
        io << (parser.kind.alias? ? " *" : " &") << anchor
      end
      if tag = parser.tag
        io << " <" << tag << '>'
      end
      io << ' ' << parser.value.inspect if parser.kind.scalar?
    end
    break if parser.kind.stream_end?
    parser.read_next
  end
  list_of_events
end

def yaml_parse(source : String, **options) : Mica::YAML::Any
  Mica::YAML.parse(source, **options, limits: YAML_LIMITS, timeout: nil)
end

# Runs the block and returns the `Mica::Error` it raises; fails when it
# raises nothing.
def yaml_error(& : ->) : Mica::Error
  yield
  fail "expected a Mica::Error"
rescue error : Mica::Error
  error
end
