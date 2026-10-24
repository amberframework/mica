# Runs the W3C XML Conformance Test Suite (xmlconf, 2013-09-23 release)
# against Mica.
#
#   crystal-alpha run --release conformance/run.cr -- /path/to/xmlconf [results.tsv]
#
# Two suites are scored separately:
#   1.0: XML 1.0 (5th edition) and Namespaces 1.0 cases; cases limited to
#        editions 1-4 are skipped.
#   1.1: XML 1.1 and Namespaces 1.1 cases (RECOMMENDATION XML1.1 / NS1.1,
#        or VERSION="1.1"), from the eduni, IBM and errata catalogs.
# NAMESPACE="no" cases are parsed without namespace processing.
#
# Expectations for a non-validating processor that never reads external
# entities:
#   valid, invalid -> must be accepted (and, for valid cases with an OUTPUT
#                     file and no external entities, must produce the same
#                     canonical XML)
#   not-wf         -> must be rejected; a not-wf case accepted while its
#                     ENTITIES attribute names external entities is reported
#                     separately (the error lives where Mica never reads)
#   error          -> reported, not scored
require "../src/mica"
require "./canonical"

record TestCase,
  id : String,
  type : String,
  uri : String,
  entities : String,
  namespace : Bool,
  output : String?,
  sections : String,
  description : String,
  catalog : String,
  suite : String

record Outcome, test : TestCase, verdict : String, detail : String

root = ARGV[0]? || abort "usage: run.cr XMLCONF_DIR [RESULTS_TSV]"
results_path = ARGV[1]?

catalogs = [
  "xmltest/xmltest.xml", "japanese/japanese.xml",
  "sun/sun-valid.xml", "sun/sun-invalid.xml", "sun/sun-not-wf.xml", "sun/sun-error.xml",
  "oasis/oasis.xml",
  "ibm/ibm_oasis_invalid.xml", "ibm/ibm_oasis_not-wf.xml", "ibm/ibm_oasis_valid.xml",
  "eduni/errata-2e/errata2e.xml", "eduni/namespaces/1.0/rmt-ns10.xml",
  "eduni/errata-3e/errata3e.xml", "eduni/namespaces/errata-1e/errata1e.xml",
  "eduni/errata-4e/errata4e.xml", "eduni/misc/ht-bh.xml",
  "eduni/xml-1.1/xml11.xml", "eduni/namespaces/1.1/rmt-ns11.xml",
  "ibm/xml-1.1/ibm_valid.xml", "ibm/xml-1.1/ibm_invalid.xml", "ibm/xml-1.1/ibm_not-wf.xml",
]

# Returns the suite ("1.0" or "1.1") a case belongs to, or nil to skip it.
def suite_of(test : Mica::XML::Node) : String?
  recommendation = test["RECOMMENDATION"]? || "XML1.0"
  versions = (test["VERSION"]? || "").split
  only_1_0 = versions.includes?("1.0") && !versions.includes?("1.1")
  if !only_1_0 && (recommendation.starts_with?("XML1.1") || recommendation.starts_with?("NS1.1") || versions.includes?("1.1"))
    return "1.1"
  end
  if edition = test["EDITION"]?
    return unless edition.split.includes?("5")
  end
  "1.0"
end

list_of_tests = [] of TestCase
skipped = 0
catalogs.each do |catalog|
  catalog_path = File.join(root, catalog)
  base = File.dirname(catalog_path)
  # Some catalogs are fragments (several top-level TEST elements), so wrap
  # the content in one element after dropping the declaration and DOCTYPE.
  text = File.read(catalog_path).sub(/\A<\?xml[^>]*\?>/, "").sub(/<!DOCTYPE[^>]*>/, "")
  document = Mica::XML.parse("<CATALOG>#{text}</CATALOG>")
  document.xpath_nodes("//TEST").each do |test|
    suite = suite_of(test)
    unless suite
      skipped += 1
      next
    end
    test_base = base
    if xml_base = test.parent.try(&.["xml:base"]?)
      test_base = File.join(base, xml_base) unless test.parent.try(&.name) == "CATALOG"
    end
    list_of_tests << TestCase.new(
      id: test["ID"],
      type: test["TYPE"],
      uri: File.join(test_base, test["URI"]),
      entities: test["ENTITIES"]? || "none",
      namespace: test["NAMESPACE"]? != "no",
      output: test["OUTPUT"]?.try { |output| File.join(test_base, output) },
      sections: test["SECTIONS"]? || "",
      description: test.content.strip.gsub(/\s+/, " "),
      catalog: catalog,
      suite: suite,
    )
  end
end

def run_case(test : TestCase) : Outcome
  bytes = File.read(test.uri).to_slice
  options = Mica::XML::ParserOptions.new(namespace_aware: test.namespace)
  begin
    document = Mica::XML.parse(bytes, options)
  rescue ex : Mica::Error
    return judge_rejection(test, ex)
  rescue ex
    return Outcome.new(test, "CRASH", "#{ex.class}: #{ex.message}")
  end
  judge_acceptance(test, document)
end

def judge_rejection(test : TestCase, error : Mica::Error) : Outcome
  case test.type
  when "valid", "invalid"
    Outcome.new(test, "FAIL", "rejected: #{error.message}")
  when "not-wf"
    Outcome.new(test, "PASS", "rejected: #{error.message}")
  else
    Outcome.new(test, "ERROR-CASE", "rejected: #{error.message}")
  end
end

def judge_acceptance(test : TestCase, document : Mica::XML::Document) : Outcome
  case test.type
  when "valid", "invalid"
    output = test.output
    if output && test.type == "valid" && test.entities == "none" && File.exists?(output)
      expected = File.read(output)
      actual = Canonical.write(document)
      return Outcome.new(test, "OUTPUT-MISMATCH", "expected #{expected.inspect} got #{actual.inspect}") unless expected == actual
      return Outcome.new(test, "PASS", "accepted, canonical output matches")
    end
    Outcome.new(test, "PASS", "accepted")
  when "not-wf"
    if test.entities != "none"
      return Outcome.new(test, "EXTERNAL-NA", "accepted; error is in an external entity Mica does not read")
    end
    if document.system_id
      # Some catalogs (IBM XML 1.1 P77) mark ENTITIES="none" for errors
      # that live in the external DTD subset.
      return Outcome.new(test, "EXTERNAL-NA", "accepted; the document has an external DTD subset Mica does not read")
    end
    Outcome.new(test, "FAIL", "accepted a not-wf document")
  else
    Outcome.new(test, "ERROR-CASE", "accepted")
  end
end

outcomes = list_of_tests.map { |test| run_case(test) }

{"1.0", "1.1"}.each do |suite|
  members = outcomes.select { |outcome| outcome.test.suite == suite }
  counts = Hash(String, Hash(String, Int32)).new { |hash, key| hash[key] = Hash(String, Int32).new(0) }
  members.each { |outcome| counts[outcome.test.type][outcome.verdict] += 1 }
  puts "xmlconf XML #{suite} applicable cases: #{members.size}"
  counts.keys.sort!.each do |type|
    verdicts = counts[type]
    total = verdicts.values.sum
    summary = verdicts.to_a.sort.map { |verdict, count| "#{verdict}=#{count}" }.join(" ")
    puts "  #{type.ljust(8)} total=#{total} #{summary}"
  end
  compared = members.count { |outcome| outcome.detail.includes?("canonical output") || outcome.verdict == "OUTPUT-MISMATCH" }
  puts "  valid cases with canonical output compared: #{compared}"
  scored = members.reject { |outcome| outcome.verdict == "ERROR-CASE" || outcome.verdict == "EXTERNAL-NA" }
  passed = scored.count { |outcome| outcome.verdict == "PASS" }
  puts "  scored: #{passed}/#{scored.size} pass"
end
puts "skipped (editions 1-4 only): #{skipped}"

failures = outcomes.select { |outcome| {"FAIL", "CRASH", "OUTPUT-MISMATCH"}.includes?(outcome.verdict) }
unless failures.empty?
  puts "\nFailures by catalog and type:"
  failures.group_by { |outcome| "#{outcome.test.catalog} #{outcome.test.type} #{outcome.verdict}" }.to_a.sort_by(&.[0]).each do |group, members|
    puts "  #{group}: #{members.size}"
    members.each do |outcome|
      puts "    #{outcome.test.id} [#{outcome.test.sections}] #{outcome.test.description[0, 90]}"
      puts "      -> #{outcome.detail[0, 200]}"
    end
  end
end

if results_path
  File.open(results_path, "w") do |file|
    outcomes.each do |outcome|
      file << outcome.test.suite << '\t' << outcome.test.id << '\t' << outcome.test.type << '\t' << outcome.verdict << '\t' << outcome.test.catalog << '\t' << outcome.detail.gsub(/[\t\n]/, " ") << '\n'
    end
  end
end
