# The reference parser for the Mica::YAML differential: libyaml, reached
# through the standard library's `LibYAML` binding, for the fuzz harness
# and the benchmarks only (the library in src/ links no C code).
# `YAMLOracle.parse` returns libyaml's event stream in the notation
# `YAMLFuzz.describe` writes for Mica, or its error.
#
# scripts/libyaml_oracle_identity.sh prints which libyaml this is.
require "yaml"

module YAMLOracle
  # What libyaml made of one input: the event lines when it parsed, or
  # the error text ("problem at L:C, context at L:C").
  record Result, list_of_events : Array(String), error : String?, error_kind : Int32

  # Returns libyaml's version, for example "0.2.5".
  def self.version : String
    LibYAML.yaml_get_version(out major, out minor, out patch)
    "#{major}.#{minor}.#{patch}"
  end

  # Parses *bytes* and describes every event, or the error that stopped
  # the parse.
  def self.parse(bytes : Bytes) : Result
    parser = Pointer(Void).malloc(LibYAML::PARSER_SIZE).as(LibYAML::Parser*)
    LibYAML.yaml_parser_initialize(parser)
    LibYAML.yaml_parser_set_input_string(parser, bytes, bytes.size)
    list_of_events = [] of String
    event = LibYAML::Event.new
    error = nil
    error_kind = 0
    loop do
      if LibYAML.yaml_parser_parse(parser, pointerof(event)) != 1
        error_kind = parser.value.error
        error = describe_error(parser)
        break
      end
      kind = event.type
      list_of_events << describe(pointerof(event))
      LibYAML.yaml_event_delete(pointerof(event))
      break if kind.stream_end? || kind.none?
    end
    LibYAML.yaml_parser_delete(parser)
    Result.new(list_of_events, error, error_kind)
  end

  private def self.describe_error(parser : LibYAML::Parser*) : String
    value = parser.value
    problem = value.problem ? String.new(value.problem) : "unknown"
    # A reader error (kind 2) carries a byte offset and no mark.
    return problem if value.error == 2
    String.build do |io|
      io << problem << " at " << value.problem_mark.line << ':' << value.problem_mark.column
      if value.context
        io << ", " << String.new(value.context) << " at " << value.context_mark.line << ':' << value.context_mark.column
      end
    end
  end

  private def self.describe(event : LibYAML::Event*) : String
    data = event.value.data
    String.build do |io|
      io << event.value.type.value << ' ' << event.value.start_mark.line << ':' << event.value.start_mark.column
      io << '-' << event.value.end_mark.line << ':' << event.value.end_mark.column
      case event.value.type
      when .document_start?
        io << " implicit" if data.document_start.implicit != 0
        if version = data.document_start.version_directive
          io << " %YAML " << version.value.major << '.' << version.value.minor
        end
        directive = data.document_start.tag_directive_start
        while directive && directive != data.document_start.tag_directive_end
          io << " %TAG " << String.new(directive.value.handle).inspect << ' ' << String.new(directive.value.prefix).inspect
          directive += 1
        end
      when .document_end?
        io << " implicit" if data.document_end.implicit != 0
      when .alias?
        io << " *" << String.new(data.alias.anchor).inspect
      when .scalar?
        scalar = data.scalar
        properties(io, scalar.anchor, scalar.tag)
        io << " plain_implicit" if scalar.plain_implicit != 0
        io << " quoted_implicit" if scalar.quoted_implicit != 0
        io << " style=" << scalar.style.value << ' '
        io << Slice.new(scalar.value, scalar.length).hexstring
      when .sequence_start?
        properties(io, data.sequence_start.anchor, data.sequence_start.tag)
        io << " implicit" if data.sequence_start.implicit != 0
        io << " style=" << data.sequence_start.style.value
      when .mapping_start?
        properties(io, data.mapping_start.anchor, data.mapping_start.tag)
        io << " implicit" if data.mapping_start.implicit != 0
        io << " style=" << data.mapping_start.style.value
      else
        # stream and collection end events carry marks only
      end
    end
  end

  private def self.properties(io : IO, anchor : UInt8*, tag : UInt8*) : Nil
    io << " &" << String.new(anchor).inspect if anchor
    io << " <" << String.new(tag).inspect << '>' if tag
  end
end
