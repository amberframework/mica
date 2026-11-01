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

    it "never resolves an external entity, so a body cannot read local files" do
      xml = %(<!DOCTYPE user [<!ENTITY secret SYSTEM "file:///etc/passwd">]><user><name>&secret;</name></user>)

      fields(xml)["name"].should eq(JSON::Any.new(""))
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
