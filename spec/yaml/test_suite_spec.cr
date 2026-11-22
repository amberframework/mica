require "./support"
require "../../conformance/yaml/suite"

# The official YAML test suite, when conformance/yaml/fetch_suite.rb has
# fetched it (conformance/run_yaml.cr prints the per-case report).
private SUITE_DATA = File.join(__DIR__, "..", "..", "conformance", "yaml-test-suite", "data")

private def suite_notation(input : Bytes) : String
  String.build do |io|
    parser = Mica::YAML::PullParser.new(input, limits: Mica::YAML::ParseLimits::TRUSTED_FILE, timeout: nil)
    loop do
      kind = parser.kind
      io << {"", "+STR", "-STR", "+DOC", "-DOC", "=ALI", "=VAL", "+SEQ", "-SEQ", "+MAP", "-MAP"}[kind.value]
      io << " ---" if kind.document_start? && !parser.implicit?
      io << " ..." if kind.document_end? && !parser.implicit?
      io << " []" if kind.sequence_start? && parser.sequence_style.flow?
      io << " {}" if kind.mapping_start? && parser.mapping_style.flow?
      if anchor = parser.anchor
        io << (kind.alias? ? " *" : " &") << anchor
      end
      if tag = parser.tag
        io << " <" << tag << '>'
      end
      if kind.scalar?
        io << ' ' << {' ', ':', '\'', '"', '|', '>'}[parser.scalar_style.value]
        YAMLSuite.escape(io, parser.value)
      end
      io << '\n'
      break if kind.stream_end?
      parser.read_next
    end
  end
end

describe "Mica::YAML and the YAML test suite" do
  if Dir.exists?(SUITE_DATA)
    it_satisfies "YAML-TEST-SUITE", "passes every case of yaml-test-suite data-2022-01-17" do
      list_of_cases = YAMLSuite.list_of_cases(SUITE_DATA)
      list_of_cases.size.should eq 402
      list_of_failures = [] of String
      list_of_cases.each do |kase|
        events = begin
          suite_notation(kase.input)
        rescue Mica::Error
          nil
        end
        verdict = YAMLSuite.verdict(kase, events)
        list_of_failures << "#{kase.id} #{verdict}" unless verdict == "pass"
      end
      list_of_failures.should eq([] of String)
    end
  else
    it_satisfies "YAML-TEST-SUITE", "passes the suite's own examples kept in this spec" do
      # The fetched suite is not here (run conformance/yaml/fetch_suite.rb
      # for all 402 cases); these are cases 229Q, 9C9N and S98Z.
      suite_notation("-\n  name: Mark McGwire\n  hr:   65\n-\n  name: Sammy Sosa\n  hr:   63\n".to_slice).should eq(
        "+STR\n+DOC\n+SEQ\n+MAP\n=VAL :name\n=VAL :Mark McGwire\n=VAL :hr\n=VAL :65\n-MAP\n+MAP\n=VAL :name\n" \
        "=VAL :Sammy Sosa\n=VAL :hr\n=VAL :63\n-MAP\n-SEQ\n-DOC\n-STR\n")
      expect_raises(Mica::YAML::SyntaxError) { suite_notation("---\nflow: [a,\nb,\nc]\n".to_slice) }
      expect_raises(Mica::YAML::SyntaxError) { suite_notation("empty block scalar: >\n \n  \n   \n # comment\n".to_slice) }
    end
  end
end
