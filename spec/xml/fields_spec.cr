require "../spec_helper"
require "../../src/mica/xml/fields"

private def fields(xml : String) : Hash(String, JSON::Any)
  Mica::XML::Fields.read(xml)
end

describe Mica::XML::Fields do
  describe ".read" do
    it "maps the root element's children to fields, as a JSON object body would" do
      result = fields(%(<user><name>Ada</name><email>ada@example.com</email></user>))

      result.should eq({
        "name"  => JSON::Any.new("Ada"),
        "email" => JSON::Any.new("ada@example.com"),
      })
    end

    it "gives the same hash as the equivalent JSON body" do
      xml = %(<order><id>42</id><customer><name>Ada</name></customer><item>tea</item><item>scones</item></order>)
      json = %({"id":"42","customer":{"name":"Ada"},"item":["tea","scones"]})

      fields(xml).should eq(JSON.parse(json).as_h)
    end

    it "turns repeated sibling names into an array in document order" do
      result = fields(%(<user><role>admin</role><role>dev</role><role>ops</role></user>))

      result["role"].should eq(JSON::Any.new(["admin", "dev", "ops"].map { |role| JSON::Any.new(role) }))
    end

    it "keeps attributes as @-prefixed keys, on the root and on nested elements" do
      result = fields(%(<book id="7"><price currency="USD">10.50</price></book>))

      result["@id"].should eq(JSON::Any.new("7"))
      result["price"].should eq(JSON::Any.new({
        "@currency" => JSON::Any.new("USD"),
        "#text"     => JSON::Any.new("10.50"),
      }))
    end

    it "reads an empty element as an empty string" do
      result = fields(%(<user><nickname/><bio></bio></user>))

      result["nickname"].should eq(JSON::Any.new(""))
      result["bio"].should eq(JSON::Any.new(""))
    end

    it "keeps a text element's value exactly, including CDATA and entities" do
      result = fields(%(<note><body><![CDATA[a <b>bold</b> claim]]></body><sign>Tom &amp; Jerry</sign></note>))

      result["body"].should eq(JSON::Any.new("a <b>bold</b> claim"))
      result["sign"].should eq(JSON::Any.new("Tom & Jerry"))
    end

    it "ignores formatting white space between elements" do
      result = fields(<<-XML)
        <user>
          <name>Ada</name>
        </user>
        XML

      result.should eq({"name" => JSON::Any.new("Ada")})
    end

    it "keeps non-blank mixed text as #text" do
      result = fields(%(<note>Hello <b>world</b> of XML</note>))

      result["#text"].should eq(JSON::Any.new("Hello  of XML"))
      result["b"].should eq(JSON::Any.new("world"))
    end

    it "names fields by local name, leaving out namespace declarations" do
      result = fields(%(<a:user xmlns:a="urn:a"><a:name>Ada</a:name></a:user>))

      result.should eq({"name" => JSON::Any.new("Ada")})
    end

    it "returns no fields for a root element with no content" do
      fields(%(<empty/>)).should eq({} of String => JSON::Any)
    end

    it "reads from an IO" do
      result = Mica::XML::Fields.read(IO::Memory.new(%(<user><name>Ada</name></user>)))

      result["name"].should eq(JSON::Any.new("Ada"))
    end

    it "raises a positioned parse error for a malformed body" do
      expect_raises(Mica::ParseError) { fields(%(<user><name>Ada</user>)) }
    end

    it "rejects nesting deeper than the request-body limit of 64 levels" do
      deep = "<a>" * 65 + "</a>" * 65

      expect_raises(Mica::LimitExceededError) { fields(deep) }
    end

    it "accepts nesting at the request-body limit" do
      at_limit = "<a>" * 64 + "x" + "</a>" * 64

      fields(at_limit).has_key?("a").should be_true
    end

    it "refuses a DTD, so no external entity, default attribute or entity text reaches the fields" do
      external = %(<!DOCTYPE user [<!ENTITY secret SYSTEM "file:///etc/passwd">]><user><name>pre&secret;post</name></user>)
      defaults = %(<!DOCTYPE r [<!ATTLIST e x CDATA "v">]><r><e/></r>)
      internal = %(<!DOCTYPE r [<!ENTITY a "aaaa">]><r><x>&a;</x></r>)

      [external, defaults, internal].each do |xml|
        expect_raises(Mica::XML::Fields::RejectedDocumentError, /DTD/) { fields(xml) }
      end
    end

    it "still reads the five predefined entities and character references" do
      fields(%(<r><x>&lt;&gt;&amp;&apos;&quot;&#65;</x></r>))["x"].should eq(JSON::Any.new(%(<>&'"A)))
    end

    it "refuses attributes that share a local name in different namespaces" do
      xml = %(<r xmlns:a="urn:a" xmlns:b="urn:b" a:id="first" b:id="second"/>)

      expect_raises(Mica::XML::Fields::RejectedDocumentError, /attributes share/) { fields(xml) }
    end

    it "refuses sibling elements that share a local name in different namespaces" do
      xml = %(<r xmlns:a="urn:a" xmlns:b="urn:b"><a:id>1</a:id><b:id>2</b:id></r>)

      expect_raises(Mica::XML::Fields::RejectedDocumentError, /elements share/) { fields(xml) }
    end

    it "keeps a text value exactly, with or without attributes" do
      result = fields(%(<r><x unit="kg">  value  </x><y>  spaced  </y><z unit="g">   </z></r>))

      result["x"].should eq(JSON::Any.new({"@unit" => JSON::Any.new("kg"), "#text" => JSON::Any.new("  value  ")}))
      result["y"].should eq(JSON::Any.new("  spaced  "))
      result["z"].should eq(JSON::Any.new({"@unit" => JSON::Any.new("g"), "#text" => JSON::Any.new("   ")}))
    end

    it "leaves #text out of an element with attributes and no text" do
      fields(%(<r><x unit="kg"/></r>))["x"].should eq(JSON::Any.new({"@unit" => JSON::Any.new("kg")}))
    end

    it "refuses a body larger than MAX_BODY_BYTES" do
      big = "<r><x>" + "a" * Mica::XML::Fields::MAX_BODY_BYTES + "</x></r>"

      expect_raises(Mica::LimitExceededError) { fields(big) }
    end

    it "caps conversion depth at MAX_DEPTH even when the caller allows deeper parsing" do
      options = Mica::XML::ParserOptions.new(max_element_depth: 100_000)
      deep = "<a>" * 1_000 + "</a>" * 1_000

      expect_raises(Mica::XML::Fields::RejectedDocumentError, /deeper than 64/) do
        Mica::XML::Fields.read(deep, options)
      end
    end

    it "charges the conversion to the same work budget as the parse" do
      wide = "<r>" + "<item>x</item>" * 2_000 + "</r>"
      parse_only = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
      Mica::XML.parse(wide, Mica::XML::ParserOptions.new(work_budget: Mica::Core::WorkBudget.unlimited), parse_only)

      # A budget that covers the parse but not the parse plus the
      # conversion stops the read.
      just_the_parse = Mica::Core::WorkBudget.new(operations_per_unit: 0, base_operations: parse_only.operations + 10)
      expect_raises(Mica::WorkBudgetExceededError) do
        Mica::XML::Fields.read(wide, Mica::XML::ParserOptions.new(work_budget: just_the_parse))
      end
    end

    it "reads a wide body with many repeated names and attributes" do
      wide = "<r>" + %(<item a="1" b="2">x</item>) * 10_000 + "</r>"
      list_of_items = fields(wide)["item"].as_a

      list_of_items.size.should eq(10_000)
      list_of_items.last.should eq(JSON::Any.new({
        "@a"    => JSON::Any.new("1"),
        "@b"    => JSON::Any.new("2"),
        "#text" => JSON::Any.new("x"),
      }))
    end

    it "stops an exponential entity expansion with a limit error" do
      entities = String.build do |io|
        io << %(<!ENTITY e0 "lol">)
        (1..12).each { |level| io << %(<!ENTITY e#{level} ") << "&e#{level - 1};" * 10 << %(">) }
      end
      xml = %(<!DOCTYPE user [#{entities}]><user><name>&e12;</name></user>)

      expect_raises(Mica::LimitExceededError) { fields(xml) }
    end
  end
end
