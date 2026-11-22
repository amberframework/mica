# Runs the official YAML test suite (yaml-test-suite, data-2022-01-17)
# against Mica::YAML's pull parser.
#
#   /usr/bin/ruby conformance/yaml/fetch_suite.rb
#   crystal-alpha run --release conformance/run_yaml.cr -- conformance/yaml-test-suite/data [yaml12|libyaml] [results.tsv]
#
# Every case has an input (in.yaml) and the event stream a parser must
# produce (test.event), or an error marker when the input is not YAML. A
# case passes when Mica produces exactly those events, or rejects the
# input when the suite marks it invalid. One line is printed per failing
# case, and a row per case goes to the results file.
#
# The dialect defaults to YAML 1.2 (`Dialect::YAML12`); `libyaml` scores
# the libyaml-compatible dialect on the same cases, for comparison with
# conformance/run_yaml_libyaml.cr.
require "../src/mica"
require "./yaml/suite"

def suite_events(source : Bytes, dialect : Mica::YAML::Dialect) : String
  String.build do |io|
    parser = Mica::YAML::PullParser.new(source, limits: Mica::YAML::ParseLimits::TRUSTED_FILE, timeout: nil,
      dialect: dialect)
    loop do
      case parser.kind
      when .stream_start?   then io << "+STR\n"
      when .stream_end?     then io << "-STR\n"
      when .document_start? then io << (parser.implicit? ? "+DOC\n" : "+DOC ---\n")
      when .document_end?   then io << (parser.implicit? ? "-DOC\n" : "-DOC ...\n")
      when .sequence_start?
        io << "+SEQ"
        io << " []" if parser.sequence_style.flow?
        properties(io, parser)
        io << '\n'
      when .sequence_end? then io << "-SEQ\n"
      when .mapping_start?
        io << "+MAP"
        io << " {}" if parser.mapping_style.flow?
        properties(io, parser)
        io << '\n'
      when .mapping_end? then io << "-MAP\n"
      when .alias?       then io << "=ALI *" << parser.anchor << '\n'
      when .scalar?
        io << "=VAL"
        properties(io, parser)
        io << ' ' << style_mark(parser.scalar_style)
        YAMLSuite.escape(io, parser.value)
        io << '\n'
      else
        raise "unexpected #{parser.kind} event"
      end
      break if parser.kind.stream_end?
      parser.read_next
    end
  end
end

def style_mark(style : Mica::YAML::ScalarStyle) : Char
  case style
  when .plain?         then ':'
  when .single_quoted? then '\''
  when .double_quoted? then '"'
  when .literal?       then '|'
  else                      '>'
  end
end

def properties(io : IO, parser : Mica::YAML::PullParser) : Nil
  if anchor = parser.anchor
    io << " &" << anchor
  end
  if tag = parser.tag
    io << " <" << tag << '>'
  end
end

root = ARGV[0]? || abort "usage: run_yaml.cr SUITE_DATA_DIR [yaml12|libyaml] [RESULTS_TSV]"
dialect = ARGV[1]? == "libyaml" ? Mica::YAML::Dialect::LibYAML : Mica::YAML::Dialect::YAML12
list_of_results = YAMLSuite.list_of_cases(root).map do |kase|
  events = nil
  detail = ""
  begin
    events = suite_events(kase.input, dialect)
    verdict = YAMLSuite.verdict(kase, events)
  rescue error : Mica::Error
    verdict = YAMLSuite.verdict(kase, nil)
    detail = error.message.to_s
  rescue error
    verdict = "crash"
    detail = "#{error.class}: #{error.message}"
  end
  {kase, verdict, detail}
end
YAMLSuite.report("Mica::YAML #{Mica::VERSION} (#{dialect})", list_of_results, ARGV[2]?)
exit(list_of_results.all? { |_, verdict, _| verdict == "pass" } ? 0 : 1)
