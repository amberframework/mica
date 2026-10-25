# Scores Mica::Form::Pairs, and stdlib URI::Params as the incumbent, on the
# web-platform-tests urlencoded parser vectors (pinned in
# conformance/form/wpt_urlencoded.json; see extract_wpt.cr).
#
#   crystal-alpha run --release conformance/form/run.cr [-- OUTPUT.tsv]
#
# A vector whose expected output holds U+FFFD tests WHATWG's replacement
# of invalid UTF-8. Mica rejects those inputs with Mica::EncodingError by
# design (nothing is ever replaced), so they score as "rejected" and are
# counted apart from failures.
require "json"
require "uri"
require "../../src/mica"

struct WptFixture
  include JSON::Serializable

  getter source : String
  getter sha256 : String
  @[JSON::Field(key: "vectors")]
  getter list_of_vectors : Array(WptVector)
end

struct WptVector
  include JSON::Serializable

  getter input : String
  # The expected pairs, each a [name, value] array.
  @[JSON::Field(key: "output")]
  getter list_of_expected_pairs : Array(Array(String))

  def replacement? : Bool
    list_of_expected_pairs.any?(&.any?(&.includes?('�')))
  end
end

fixture = WptFixture.from_json(File.read(File.join(__DIR__, "wpt_urlencoded.json")))
limits = Mica::Form::Limits::REQUEST_BODY
rows = [] of String
mica_pass = mica_rejected = mica_fail = stdlib_pass = stdlib_fail = 0

fixture.list_of_vectors.each_with_index do |vector, index|
  expected = vector.list_of_expected_pairs.map { |pair| {pair[0], pair[1]} }
  mica = begin
    got = Mica::Form::Pairs.parse(vector.input, limits: limits).map { |pair| {pair.field_name, pair.field_value} }
    got == expected ? "pass" : "fail #{got.inspect}"
  rescue error : Mica::EncodingError
    vector.replacement? ? "rejected #{error.byte_offset}" : "fail #{error.message}"
  end
  stdlib_pairs = [] of {String, String}
  URI::Params.parse(vector.input) { |name, value| stdlib_pairs << {name, value} }
  stdlib = stdlib_pairs == expected ? "pass" : "fail #{stdlib_pairs.inspect}"
  case mica
  when "pass"                     then mica_pass += 1
  when .starts_with?("rejected ") then mica_rejected += 1
  else                                 mica_fail += 1
  end
  stdlib == "pass" ? (stdlib_pass += 1) : (stdlib_fail += 1)
  rows << "#{index}\t#{vector.input.inspect}\t#{mica}\t#{stdlib}"
end

total = fixture.list_of_vectors.size
puts "wpt urlencoded vectors (#{fixture.source}, sha256 #{fixture.sha256}): #{total}"
puts "Mica::Form::Pairs: #{mica_pass} pass, #{mica_rejected} rejected by the strict UTF-8 policy, #{mica_fail} fail"
puts "stdlib URI::Params: #{stdlib_pass} pass, #{stdlib_fail} fail"
if path = ARGV[0]?
  File.write(path, "case\tinput\tmica\tstdlib\n" + rows.join('\n') + '\n')
end
exit(mica_fail == 0 ? 0 : 1)
