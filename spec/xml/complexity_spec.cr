require "../spec_helper"

# Linear-time proofs. Each example builds an adversarial input at size count and
# 4n, counts the operations Mica charges to its work meter (never wall
# time), and requires the count to grow by at most 4 * 1.25. A quadratic
# path grows by 16. The shapes include the REXML 2024 CVE inputs.

# Limits opened wide so only the algorithm, not a limit, decides the work.
private OPEN = Mica::XML::ParserOptions.new(
  max_entity_expansions: Int32::MAX,
  max_entity_expansion_bytes: Int64::MAX,
  max_default_attributes: Int32::MAX,
  max_default_attribute_bytes: Int64::MAX,
  max_element_depth: 1_000_000,
  max_name_bytes: Int32::MAX,
  max_attributes: Int32::MAX,
  max_token_bytes: 1 << 30,
  work_budget: Mica::Core::WorkBudget.unlimited,
)

private OPEN_11 = OPEN

# Operations a full DOM parse of *xml* charges; a parse error ends the count
# where the error was found.
private def parse_operations(xml : String | Bytes, options : Mica::XML::ParserOptions = OPEN) : Int64
  meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
  begin
    Mica::XML.parse(xml, options, meter)
  rescue Mica::ParseError
  end
  meter.operations
end

# Operations a streaming read of *bytes* through a 1-byte IO charges.
private def trickle_operations(bytes : Bytes) : Int64
  meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
  reader = Mica::XML::Reader.new(TrickleIO.new(bytes, 1), OPEN, meter)
  while reader.read
  end
  meter.operations
end

private def xpath_operations(document : Mica::XML::Document, path : String) : Int64
  meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
  document.xpath(path, meter: meter)
  meter.operations
end

private def linear(name : String, size : Int32, & : Int32 -> Int64) : Nil
  result = Mica::Testing::Complexity.measure(name, size) { |count| yield count }
  COMPLEXITY_RESULTS << result
  fail(result.to_s) unless result.linear?
  result.small.should be > 10_000
end

describe "Mica::XML linear time (operation counts at count and 4n)" do
  describe "attributes" do
    it_satisfies "MICA-LINEAR-ATTRIBUTES", "checks duplicates on one very wide element" do
      linear("wide element, duplicate check", 5_000) { |count| parse_operations("<a " + (1..count).join(' ') { |i| %(a#{i}="1") } + "/>") }
    end

    it_satisfies "MICA-LINEAR-CVE-2024-43398", "handles deep elements whose attributes share a local name (CVE-2024-43398 shape)" do
      linear("deep same-local-name attributes", 2_000) do |count|
        root = %(<r xmlns:p="u1" xmlns:q="u2" xmlns:s="u3">)
        parse_operations(root + %(<e p:a="1" q:a="2" s:a="3" a="4">) * count + "</e>" * count + "</r>")
      end
    end

    it_satisfies "MICA-LINEAR-NAMESPACES", "resolves prefixes against many in-scope declarations" do
      linear("many declarations, many prefixed names", 2_000) do |count|
        declarations = (1..count).join(' ') { |i| %(xmlns:p#{i}="urn:#{i}") }
        parse_operations(%(<r #{declarations}>) + "<p1:e p1:a='1'/>" * count + "</r>")
      end
    end

    it "resolves prefixes declared at every level of a deep tree" do
      linear("nested declarations", 2_000) do |count|
        open_tags = (1..count).join { |i| %(<e xmlns:p#{i}="urn:#{i}">) }
        parse_operations("<r xmlns:p0='urn:0'>" + open_tags + "<p0:leaf p0:a='1'/>" * count + "</e>" * count + "</r>")
      end
    end

    it_satisfies "MICA-LINEAR-ATTLIST", "applies many ATTLIST declarations to many elements" do
      linear("many #IMPLIED declarations x many elements", 2_000) do |count|
        declarations = (1..count).join { |i| "<!ATTLIST e a#{i} CDATA #IMPLIED>" }
        parse_operations("<!DOCTYPE r [#{declarations}<!ATTLIST e t NMTOKENS #IMPLIED>]><r>" + "<e t=' x  y '/>" * count + "</r>")
      end
    end

    it_satisfies "MICA-LINEAR-CVE-2024-35176", "stops at the first '<' in an attribute value and scans escaped '<' linearly (CVE-2024-35176 shape)" do
      linear("many &lt; in an attribute value", 50_000) { |count| parse_operations(%(<a v="#{"&lt;" * count}"/>)) }
      linear("many < in an attribute value", 50_000) { |count| parse_operations(%(<a v="x) + "<" * count + %("/>)) + count }
    end

    it "normalizes attribute values with long white-space runs" do
      linear("attribute white space", 100_000) { |count| parse_operations(%(<a v="#{"\t\r\n " * count}"/>)) }
    end
  end

  describe "text and references" do
    it "scans long text, multibyte text and CRLF runs" do
      linear("long text", 200_000) { |count| parse_operations("<a>#{"x" * count}</a>") }
      linear("multibyte text", 50_000) { |count| parse_operations("<a>#{"é😀" * count}</a>") }
      linear("CRLF runs", 100_000) { |count| parse_operations("<a>#{"\r\n" * count}</a>") }
    end

    it_satisfies "MICA-LINEAR-CHARREF", "expands many character references and very long ones (CVE-2024-49761 shape)" do
      linear("many character references", 50_000) { |count| parse_operations("<a>#{"&#65;&#x42;" * count}</a>") }
      linear("long decimal reference", 100_000) { |count| parse_operations("<a>&##{"0" * count}65;</a>") }
      linear("long hex reference", 100_000) { |count| parse_operations("<a>&#x#{"0" * count}41;</a>") }
      linear("unterminated digit runs", 50_000) { |count| parse_operations("<a>#{"&#" + "0" * 20 + "x;"}#{"1" * count}</a>") + count }
    end

    it_satisfies "MICA-LINEAR-ENTITIES", "expands many entity references (CVE-2024-41946 shape, pull parser)" do
      linear("text entity references", 20_000) { |count| parse_operations(%(<!DOCTYPE r [<!ENTITY e "text">]><r>#{"&e;" * count}</r>)) }
      linear("markup entity references", 10_000) { |count| parse_operations(%(<!DOCTYPE r [<!ENTITY e "<b>x</b>">]><r>#{"&e;" * count}</r>)) }
      linear("nested entity references", 5_000) do |count|
        parse_operations(%(<!DOCTYPE r [<!ENTITY a "aa"><!ENTITY b "&a;&a;<i/>">]><r>#{"&b;" * count}</r>))
      end
      linear("entities in attribute values", 10_000) do |count|
        parse_operations(%(<!DOCTYPE r [<!ENTITY a "x&#32;y"><!ENTITY b "&a;&a;">]><r v="#{"&b;" * count}"/>))
      end
    end

    it "merges text split at many entity boundaries into one DOM node" do
      linear("text merged across entity boundaries", 10_000) do |count|
        parse_operations(%(<!DOCTYPE r [<!ENTITY e "]">]><r>#{"text&e;" * count}</r>))
      end
    end

    it_satisfies "MICA-LINEAR-CVE-2024-41123", "scans text full of ']', '>]', ']>' and white space (CVE-2024-41123 shape)" do
      linear("']>' runs", 50_000) { |count| parse_operations("<a>#{"]>" * count}</a>") }
      linear("'>]' runs", 50_000) { |count| parse_operations("<a>#{">]" * count}</a>") }
      linear("']' runs", 100_000) { |count| parse_operations("<a>#{"]" * count}</a>") }
      linear("white space between attributes", 100_000) { |count| parse_operations("<a#{" " * count}b='1'#{"\n" * count}/>") }
      linear("white space in content", 100_000) { |count| parse_operations("<a>#{" \t\n" * count}</a>") }
    end
  end

  describe "markup scanning" do
    it_satisfies "MICA-LINEAR-CVE-2024-39908", "scans comments, PIs and CDATA full of terminator lookalikes (CVE-2024-39908 shape)" do
      linear("comment of '-x'", 50_000) { |count| parse_operations("<a><!--#{"-x" * count}--></a>") }
      linear("comment of '<'", 100_000) { |count| parse_operations("<a><!--#{"<" * count}--></a>") }
      linear("PI of '?x' and '%>'", 50_000) { |count| parse_operations("<a><?p #{"?x%>" * count}?></a>") }
      linear("CDATA of ']' runs", 50_000) { |count| parse_operations("<a><![CDATA[#{"]]x]" * count}]]></a>") }
      linear("text of '0'", 200_000) { |count| parse_operations("<a>#{"0" * count}</a>") }
    end

    it_satisfies "MICA-LINEAR-STRUCTURE", "handles long names, many siblings and deep nesting" do
      linear("long element name", 100_000) { |count| name = "count" * count; parse_operations("<#{name}></#{name}>") }
      linear("many siblings", 50_000) { |count| parse_operations("<r>#{"<b/>" * count}</r>") }
      linear("deep nesting", 20_000) { |count| parse_operations("<a>" * count + "</a>" * count) }
      linear("deep nesting, wide names", 5_000) { |count| parse_operations("<abcdefgh>" * count + "</abcdefgh>" * count) }
    end
  end

  describe "DTD" do
    it_satisfies "MICA-LINEAR-DTD", "parses wide content models, enumerations and many declarations" do
      linear("wide choice content model", 20_000) { |count| parse_operations("<!DOCTYPE r [<!ELEMENT r (#{(1..count).join('|') { |i| "e#{i}" }})*>]><r/>") }
      linear("wide mixed content model", 20_000) { |count| parse_operations("<!DOCTYPE r [<!ELEMENT r (#PCDATA|#{(1..count).join('|') { |i| "e#{i}" }})*>]><r/>") }
      linear("wide enumeration", 20_000) { |count| parse_operations("<!DOCTYPE r [<!ATTLIST r a (#{(1..count).join('|') { |i| "v#{i}" }}) #IMPLIED>]><r/>") }
      linear("many entity declarations", 10_000) { |count| parse_operations("<!DOCTYPE r [#{(1..count).join { |i| %(<!ENTITY e#{i} "v#{i}">) }}]><r/>") }
      linear("long entity value", 100_000) { |count| parse_operations(%(<!DOCTYPE r [<!ENTITY e "#{"v&#65;" * count}">]><r/>)) }
      linear("many defaulted attributes", 2_000) do |count|
        declarations = (1..20).join { |i| %(<!ATTLIST e d#{i} CDATA "v">) }
        parse_operations("<!DOCTYPE r [#{declarations}]><r>#{"<e/>" * count}</r>")
      end
      linear("nested content groups (bounded at 256 levels)", 5_000) do |count|
        group = "(" * 200 + "a" + ")" * 200
        parse_operations("<!DOCTYPE r [#{(1..count // 100).join { |i| "<!ELEMENT e#{i} #{group}>" }}]><r/>") + count
      end
    end
  end

  describe "input handling" do
    it_satisfies "MICA-LINEAR-STREAMING", "moves each byte O(1) times through a 1-byte IO" do
      linear("1-byte trickle IO", 20_000) { |count| trickle_operations("<r>#{"<b a='1'>t</b>" * count}</r>".to_slice) }
      [20_000, 80_000].each do |count|
        bytes = "<r><!--#{"x" * count}-->#{"<b a='1'>t</b>" * count}</r>".to_slice
        reader = Mica::XML::Reader.new(TrickleIO.new(bytes, 1), OPEN)
        while reader.read
        end
        reader.input_bytes_moved.should be <= 3 * bytes.size
      end
      [20_000, 80_000].each do |count|
        bytes = "<!DOCTYPE r [#{(1..count // 10).join { |i| %(<!ENTITY e#{i} "v">) }}]><r/>".to_slice
        reader = Mica::XML::Reader.new(TrickleIO.new(bytes, 1), OPEN)
        while reader.read
        end
        reader.input_bytes_moved.should be <= 3 * bytes.size
      end
    end

    it_satisfies "MICA-LINEAR-POSITION", "answers line and column after every event on a one-line document" do
      linear("position after every event", 20_000) do |count|
        meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
        reader = Mica::XML::Reader.new("<r>#{"<b a='1'>t</b>" * count}</r>", OPEN, meter)
        while reader.read
          reader.column_number
          if reader.move_to_first_attribute
            reader.column_number
            reader.move_to_element
          end
        end
        meter.operations
      end
    end

    it "decodes UTF-16, ISO-8859-1 and XML 1.1 line ends linearly" do
      linear("UTF-16 input", 20_000) { |count| parse_operations(utf16("<r>#{"<b>tëxt</b>" * count}</r>", false)) }
      linear("ISO-8859-1 input", 20_000) { |count| parse_operations(%(<?xml version="1.0" encoding="ISO-8859-1"?><r>#{"<b>t\xE9xt</b>" * count}</r>).to_slice) }
      linear("XML 1.1 NEL and LSEP line ends", 50_000) { |count| parse_operations(%(<?xml version="1.1"?><r>#{"x\u0085y " * count}</r>), OPEN_11) }
    end
  end

  describe "XPath" do
    deep = ->(count : Int32) { Mica::XML.parse("<r>" + "<a><b><c>t</c></b></a>" * (count // 4) + "<a>" * 200 + "<b><c/></b>" + "</a>" * 200 + "</r>", OPEN) }
    wide = ->(count : Int32) { Mica::XML.parse("<r>#{(1..count).join { |i| %(<s count="#{i}">#{i}</s>) }}</r>", OPEN) }

    it_satisfies "MICA-LINEAR-XPATH-DESCENDANT", "evaluates // chains without revisiting subtrees" do
      linear("//a//b//c", 4_000) { |count| xpath_operations(deep.call(count), "//a//b//c") }
      linear("//*//*", 4_000) { |count| xpath_operations(deep.call(count), "count(//*//*)") }
      linear("descendant-or-self chains", 4_000) { |count| xpath_operations(deep.call(count), "count(//a/descendant-or-self::*/descendant::c)") }
    end

    it_satisfies "MICA-LINEAR-XPATH-AXES", "evaluates sibling, following, preceding and ancestor axes from many contexts" do
      linear("following-sibling", 4_000) { |count| xpath_operations(wide.call(count), "count(//s/following-sibling::*)") }
      linear("preceding-sibling", 4_000) { |count| xpath_operations(wide.call(count), "count(//s/preceding-sibling::*)") }
      linear("following", 4_000) { |count| xpath_operations(wide.call(count), "count(//s/following::*)") }
      linear("preceding", 4_000) { |count| xpath_operations(wide.call(count), "count(//s/preceding::*)") }
      linear("ancestor", 4_000) { |count| xpath_operations(deep.call(count), "count(//c/ancestor::*)") }
      linear("parent", 4_000) { |count| xpath_operations(wide.call(count), "count(//s/..)") }
      linear("union", 4_000) { |count| xpath_operations(wide.call(count), "count(//s | //s/text() | /r)") }
      linear("first-child predicate per context", 4_000) { |count| xpath_operations(wide.call(count), "count(//s/text()[1])") }
    end

    it_satisfies "MICA-LINEAR-XPATH-COMPARE", "compares node sets and runs string functions in linear time" do
      linear("node set = node set", 4_000) { |count| xpath_operations(wide.call(count), "//s[1] = //s") }
      linear("node set != node set", 4_000) { |count| xpath_operations(wide.call(count), "//s != //s") }
      linear("node set < node set", 4_000) { |count| xpath_operations(wide.call(count), "//s < //s") }
      linear("translate", 20_000) { |count| xpath_operations(wide.call(10), "translate('#{"abc" * count}', '#{"abcdefghij" * 50}', 'xyz')") }
      linear("contains, adversarial needle", 20_000) { |count| xpath_operations(wide.call(10), "contains('#{"a" * count}', '#{"a" * (count // 2)}b')") }
      linear("substring-before", 20_000) { |count| xpath_operations(wide.call(10), "substring-before('#{"ab" * count}', '#{"ab" * (count // 4)}c')") }
      linear("normalize-space", 20_000) { |count| xpath_operations(wide.call(10), "normalize-space('#{" a  b " * count}')") }
      linear("number()", 20_000) { |count| xpath_operations(wide.call(10), "number('#{"1" * count}.#{"0" * count}')") }
    end
  end
end

describe Mica::Testing::Complexity do
  it "rejects a quadratic workload" do
    result = Mica::Testing::Complexity.measure("quadratic probe", 1_000) { |count| count.to_i64 * count }
    result.linear?.should be_false
    result.ratio.should eq(16.0)
  end

  it "rejects an XPath workload with nested predicates (inherently quadratic) unless budgeted" do
    document = ->(count : Int32) { Mica::XML.parse("<r>#{"<s>1</s>" * count}</r>") }
    result = Mica::Testing::Complexity.measure("nested predicate", 500) do |count|
      xpath_operations(document.call(count), "count(//s[//s = .])")
    end
    result.linear?.should be_false
    expect_raises(Mica::WorkBudgetExceededError) do
      document.call(20_000).xpath("count(//s[//s = .])")
    end
  end
end
