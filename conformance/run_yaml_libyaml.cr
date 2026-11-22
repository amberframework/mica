# Runs the official YAML test suite against libyaml (through the standard
# library's binding), as the baseline for conformance/run_yaml.cr.
#
#   crystal-alpha run --release conformance/run_yaml_libyaml.cr -- conformance/yaml-test-suite/data [results.tsv]
require "yaml"
require "./yaml/suite"

def libyaml_events(source : Bytes) : String?
  parser = Pointer(Void).malloc(LibYAML::PARSER_SIZE).as(LibYAML::Parser*)
  LibYAML.yaml_parser_initialize(parser)
  LibYAML.yaml_parser_set_input_string(parser, source, source.size)
  event = LibYAML::Event.new
  failed = false
  text = String.build do |io|
    loop do
      if LibYAML.yaml_parser_parse(parser, pointerof(event)) != 1
        failed = true
        break
      end
      kind = event.type
      data = event.data
      case kind
      when .stream_start?   then io << "+STR\n"
      when .stream_end?     then io << "-STR\n"
      when .document_start? then io << (data.document_start.implicit != 0 ? "+DOC\n" : "+DOC ---\n")
      when .document_end?   then io << (data.document_end.implicit != 0 ? "-DOC\n" : "-DOC ...\n")
      when .sequence_start?
        io << "+SEQ"
        io << " []" if data.sequence_start.style.flow?
        properties(io, data.sequence_start.anchor, data.sequence_start.tag)
        io << '\n'
      when .sequence_end? then io << "-SEQ\n"
      when .mapping_start?
        io << "+MAP"
        io << " {}" if data.mapping_start.style.flow?
        properties(io, data.mapping_start.anchor, data.mapping_start.tag)
        io << '\n'
      when .mapping_end? then io << "-MAP\n"
      when .alias?       then io << "=ALI *" << String.new(data.alias.anchor) << '\n'
      when .scalar?
        io << "=VAL"
        properties(io, data.scalar.anchor, data.scalar.tag)
        io << ' ' << style_mark(data.scalar.style)
        YAMLSuite.escape(io, String.new(data.scalar.value, data.scalar.length))
        io << '\n'
      else
        # an empty event after the stream end
      end
      LibYAML.yaml_event_delete(pointerof(event))
      break if kind.stream_end? || kind.none?
    end
  end
  LibYAML.yaml_parser_delete(parser)
  failed ? nil : text
end

def style_mark(style : YAML::ScalarStyle) : Char
  case style
  when .plain?         then ':'
  when .single_quoted? then '\''
  when .double_quoted? then '"'
  when .literal?       then '|'
  else                      '>'
  end
end

def properties(io : IO, anchor : UInt8*, tag : UInt8*) : Nil
  io << " &" << String.new(anchor) if anchor
  io << " <" << String.new(tag) << '>' if tag
end

root = ARGV[0]? || abort "usage: run_yaml_libyaml.cr SUITE_DATA_DIR [RESULTS_TSV]"
list_of_results = YAMLSuite.list_of_cases(root).map do |kase|
  {kase, YAMLSuite.verdict(kase, libyaml_events(kase.input)), ""}
end
YAMLSuite.report("libyaml #{YAML.libyaml_version}", list_of_results, ARGV[1]?)
