# Describes Mica::YAML events and errors in the notation fuzz/yaml_oracle.cr
# writes for libyaml, so the two can be compared as text. Shared by the
# differential harness and spec/yaml/libyaml_replay_spec.cr; needs no
# libyaml.
require "../src/mica"

module YAMLEvents
  # Describes every event of *parser* in the notation of `YAMLOracle`.
  def self.describe(parser : Mica::YAML::PullParser) : Array(String)
    list_of_events = [] of String
    loop do
      kind = parser.kind
      list_of_events << String.build do |io|
        io << kind.value << ' ' << parser.start_line - 1 << ':' << parser.start_column - 1
        io << '-' << parser.end_line - 1 << ':' << parser.end_column - 1
        case kind
        when .document_start?
          io << " implicit" if parser.implicit?
          if version = parser.version_directive
            io << " %YAML " << version[0] << '.' << version[1]
          end
          parser.list_of_tag_directives.each { |pair| io << " %TAG " << pair[0].inspect << ' ' << pair[1].inspect }
        when .document_end?
          io << " implicit" if parser.implicit?
        when .alias?
          io << " *" << parser.anchor.to_s.inspect
        when .scalar?
          properties(io, parser)
          io << " plain_implicit" if parser.plain_implicit?
          io << " quoted_implicit" if parser.quoted_implicit?
          io << " style=" << parser.scalar_style.value << ' ' << parser.value.to_slice.hexstring
        when .sequence_start?
          properties(io, parser)
          io << " implicit" if parser.implicit?
          io << " style=" << parser.sequence_style.value
        when .mapping_start?
          properties(io, parser)
          io << " implicit" if parser.implicit?
          io << " style=" << parser.mapping_style.value
        else
          # stream and collection end events carry marks only
        end
      end
      break if kind.stream_end? || kind.none?
      parser.read_next
    end
    list_of_events
  end

  private def self.properties(io : IO, parser : Mica::YAML::PullParser) : Nil
    if anchor = parser.anchor
      io << " &" << anchor.inspect
    end
    if tag = parser.tag
      io << " <" << tag.inspect << '>'
    end
  end

  # Describes a Mica syntax error the way `YAMLOracle` describes
  # libyaml's.
  def self.describe_error(error : Mica::Error) : String
    if error.is_a?(Mica::YAML::SyntaxError)
      String.build do |io|
        io << error.detail << " at " << error.line_number - 1 << ':' << error.column_number - 1
        context = error.context
        context_position = error.context_position
        if context && context_position
          io << ", " << context << " at " << context_position.line - 1 << ':' << context_position.column - 1
        end
      end
    elsif error.is_a?(Mica::ParseError)
      error.detail
    else
      error.message.to_s
    end
  end
end
