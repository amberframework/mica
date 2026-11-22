# Checks Mica::YAML.parse_all (node API, core schema) against the JSON
# form the YAML test suite gives for its valid cases (in.json).
#
#   crystal-alpha run --release conformance/run_yaml_values.cr -- conformance/yaml-test-suite/data [results.tsv]
#
# A case passes when every document parses to the value in.json holds for
# it. Cases without in.json (their values have no JSON form: non-string
# keys, cyclic or tagged data) are not scored.
require "json"
require "../src/mica"
require "./yaml/suite"

# Returns true when a parsed YAML value equals a JSON value. Numbers
# compare by value, so 1 and 1.0 match.
def same_value?(yaml : Mica::YAML::Any, json : JSON::Any) : Bool
  raw = yaml.raw
  expected = json.raw
  if raw.is_a?(Array)
    return false unless expected.is_a?(Array) && raw.size == expected.size
    raw.each_with_index { |item, index| return false unless same_value?(item, expected[index]) }
    true
  elsif raw.is_a?(Hash)
    return false unless expected.is_a?(Hash) && raw.size == expected.size
    raw.each do |key, value|
      key_text = key.raw
      return false unless key_text.is_a?(String)
      other = expected[key_text]?
      return false unless other && same_value?(value, other)
    end
    true
  elsif raw.is_a?(Int64) || raw.is_a?(Float64)
    (expected.is_a?(Int64) || expected.is_a?(Float64)) && raw == expected
  else
    raw == expected
  end
end

# Splits a file of concatenated JSON values (in.json holds one per YAML
# document) into the text of each value.
def split_json_documents(text : String) : Array(String)
  list_of_documents = [] of String
  reader = Char::Reader.new(text)
  while reader.has_next?
    if reader.current_char.whitespace?
      reader.next_char
      next
    end
    start = reader.pos
    depth = 0
    in_string = false
    while reader.has_next?
      char = reader.current_char
      if in_string
        if char == '\\'
          reader.next_char
        elsif char == '"'
          in_string = false
        end
      elsif char == '"'
        in_string = true
      elsif char == '{' || char == '['
        depth += 1
      elsif char == '}' || char == ']'
        depth -= 1
      elsif depth == 0 && char.whitespace?
        break
      end
      reader.next_char
      break if depth == 0 && !in_string && (char == '}' || char == ']' || char == '"')
    end
    list_of_documents << text.byte_slice(start, reader.pos - start)
  end
  list_of_documents
end

root = ARGV[0]? || abort "usage: run_yaml_values.cr SUITE_DATA_DIR [RESULTS_TSV]"
list_of_results = [] of {YAMLSuite::Case, String, String}
YAMLSuite.list_of_cases(root).each do |kase|
  json_path = File.join(root, kase.id, "in.json")
  next if kase.is_invalid || !File.exists?(json_path)
  list_of_expected = split_json_documents(File.read(json_path)).map { |text| JSON.parse(text) }
  verdict = "pass"
  detail = ""
  begin
    list_of_values = Mica::YAML.parse_all(kase.input, limits: Mica::YAML::ParseLimits::TRUSTED_FILE, timeout: nil)
    same = list_of_values.size == list_of_expected.size &&
           list_of_values.each_with_index.all? { |value, index| same_value?(value, list_of_expected[index]) }
    unless same
      verdict = "wrong-events"
      detail = "got #{list_of_values.inspect[0, 120]}"
    end
  rescue error : Mica::Error
    verdict = "rejected-valid"
    detail = error.message.to_s
  rescue error
    verdict = "crash"
    detail = "#{error.class}: #{error.message}"
  end
  list_of_results << {kase, verdict, detail}
end
YAMLSuite.report("Mica::YAML #{Mica::VERSION} values (wrong-events counts wrong values)", list_of_results, ARGV[1]?)
exit(list_of_results.all? { |_, verdict, _| verdict == "pass" } ? 0 : 1)
