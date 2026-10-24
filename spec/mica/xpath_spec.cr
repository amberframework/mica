require "../spec_helper"

private S3 = <<-XML
  <?xml version="1.0" encoding="UTF-8"?>
  <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <Name>bucket</Name>
    <IsTruncated>false</IsTruncated>
    <Contents><Key>a.txt</Key><Size>10</Size><StorageClass>STANDARD</StorageClass></Contents>
    <Contents><Key>b/c.txt</Key><Size>32</Size><StorageClass>GLACIER</StorageClass></Contents>
    <Contents><Key>d.txt</Key><Size>5</Size><StorageClass>STANDARD</StorageClass></Contents>
  </ListBucketResult>
  XML

private S3_NS = {"s3" => "http://s3.amazonaws.com/doc/2006-03-01/"}

private DOC = <<-XML
  <root>
    <a id="1" kind="x"><b>one</b><b>two</b></a>
    <a id="2"><b>three</b><c>c-text</c></a>
    <a id="3" kind="y"/>
    <!-- note -->
    <?target data?>
  </root>
  XML

private def keys(path : String, namespaces = S3_NS) : Array(String)
  Mica.parse(S3).xpath_nodes(path, namespaces).map(&.content)
end

private def values(path : String) : Array(String)
  Mica.parse(DOC).xpath_nodes(path).map(&.content)
end

describe Mica::XPath do
  describe "S3 responses with a prefix map" do
    it "selects child and descendant paths" do
      keys("/s3:ListBucketResult/s3:Contents/s3:Key").should eq(["a.txt", "b/c.txt", "d.txt"])
      keys("//s3:Key").should eq(["a.txt", "b/c.txt", "d.txt"])
      keys("//s3:Contents[s3:StorageClass='GLACIER']/s3:Key").should eq(["b/c.txt"])
      keys("//s3:Contents[2]/s3:Key").should eq(["b/c.txt"])
      keys("//s3:Contents[last()]/s3:Key").should eq(["d.txt"])
      keys("//s3:Contents[s3:Size > 8]/s3:Key").should eq(["a.txt", "b/c.txt"])
    end

    it "registers the root's namespaces when no map is given (default as xmlns)" do
      document = Mica.parse(S3)
      document.xpath_nodes("//xmlns:Key").size.should eq(3)
      document.xpath_string("string(//xmlns:Name)").should eq("bucket")
    end

    it "matches nothing for unprefixed names in a namespace" do
      keys("//Key").should be_empty
    end

    it "raises for an undefined prefix" do
      expect_raises(Mica::XPathError, /Undefined namespace prefix/) { keys("//zz:Key") }
    end

    it "evaluates numbers, strings and booleans" do
      document = Mica.parse(S3)
      document.xpath_float("count(//s3:Contents)", S3_NS).should eq(3.0)
      document.xpath_float("sum(//s3:Size)", S3_NS).should eq(47.0)
      document.xpath_bool("//s3:IsTruncated = 'true'", S3_NS).should be_false
      document.xpath_string("concat(//s3:Name, '/', //s3:Contents[1]/s3:Key)", S3_NS).should eq("bucket/a.txt")
      document.xpath("count(//s3:Key) > 2", S3_NS).should be_true
    end
  end

  describe "location paths" do
    it "supports abbreviations and axes" do
      values("/root/a/b").should eq(["one", "two", "three"])
      values("//a[@id='2']/*").should eq(["three", "c-text"])
      values("//b[1]").should eq(["one", "three"])
      values("(//b)[1]").should eq(["one"])
      values("//c/..").map(&.strip).should eq(["threec-text"])
      values("//c/parent::a/@id").should eq(["2"])
      values("//b[.='two']/preceding-sibling::b").should eq(["one"])
      values("//b[.='one']/following-sibling::*").should eq(["two"])
      values("//c/ancestor::*").size.should eq(2)
      values("//c/ancestor::a[1]/@id").should eq(["2"])
      values("//b[.='three']/preceding::b").should eq(["one", "two"])
      values("//b[.='two']/following::*").should eq(["threec-text", "three", "c-text", ""])
      values("//a[@id='3']/self::a/@kind").should eq(["y"])
      values("//a/descendant-or-self::*[@id='1']/@kind").should eq(["x"])
      values("//a[@kind]/@id").should eq(["1", "3"])
      values("//a[not(@kind)]/@id").should eq(["2"])
      values("//a[@id > 1 and @kind = 'y']/@id").should eq(["3"])
      values("//a[@id = 1 or @id = 3]/@id").should eq(["1", "3"])
      values("//a/@*").should eq(["1", "x", "2", "3", "y"])
    end

    it "uses proximity positions on reverse axes" do
      values("//c/preceding-sibling::*[1]").should eq(["three"])
      values("//b[.='two']/preceding::*[1]").should eq(["one"])
      values("//c/ancestor-or-self::*[2]/@id").should eq(["2"])
    end

    it "selects text, comments and PIs" do
      values("//b/text()").should eq(["one", "two", "three"])
      Mica.parse(DOC).xpath_nodes("//comment()").map(&.content).should eq([" note "])
      Mica.parse(DOC).xpath_nodes("//processing-instruction('target')").size.should eq(1)
      Mica.parse(DOC).xpath_nodes("//processing-instruction('other')").size.should eq(0)
      Mica.parse(DOC).xpath_nodes("/root/node()").size.should eq(11)
    end

    it "unions in document order without duplicates" do
      values("//c | //b | //b[1]").should eq(["one", "two", "three", "c-text"])
    end

    it "selects the document node with /" do
      Mica.parse(DOC).xpath_nodes("/").first.document?.should be_true
    end

    it "evaluates relative to a context node" do
      second = node_at(Mica.parse(DOC), "//a[2]")
      second.xpath_nodes("b").map(&.content).should eq(["three"])
      second.xpath_nodes(".//c").map(&.content).should eq(["c-text"])
      second.xpath_string("string(@id)").should eq("2")
    end
  end

  describe "functions" do
    it "implements the core string functions" do
      document = Mica.parse(%(<r><s>  Hello   World  </s></r>))
      document.xpath_string("normalize-space(//s)").should eq("Hello World")
      document.xpath_string("substring('12345', 2, 3)").should eq("234")
      document.xpath_string("substring('12345', 1.5, 2.6)").should eq("234")
      document.xpath_string("substring('12345', 0, 3)").should eq("12")
      document.xpath_string("substring-before('a/b', '/')").should eq("a")
      document.xpath_string("substring-after('a/b', '/')").should eq("b")
      document.xpath_string("translate('bar', 'abc', 'ABC')").should eq("BAr")
      document.xpath_string("translate('--aaa--', 'abc-', 'ABC')").should eq("AAA")
      document.xpath_float("string-length('héllo')").should eq(5.0)
      document.xpath_bool("starts-with('crystal', 'cry')").should be_true
      document.xpath_bool("contains('crystal', 'yst')").should be_true
      document.xpath_string("name(/r/s)").should eq("s")
      document.xpath_string("local-name(/r)").should eq("r")
    end

    it "implements number functions and XPath number formatting" do
      document = Mica.parse("<r/>")
      document.xpath_float("floor(2.7)").should eq(2.0)
      document.xpath_float("ceiling(2.1)").should eq(3.0)
      document.xpath_float("round(2.5)").should eq(3.0)
      document.xpath_float("round(-2.5)").should eq(-2.0)
      document.xpath_float("7 mod 3").should eq(1.0)
      document.xpath_float("6 div 4").should eq(1.5)
      document.xpath_float("-(2 + 3) * 2").should eq(-10.0)
      document.xpath_string("string(1 div 0)").should eq("Infinity")
      document.xpath_string("string(0 div 0)").should eq("NaN")
      document.xpath_string("string(3)").should eq("3")
      document.xpath_string("string(0.5)").should eq("0.5")
      document.xpath_string("string(0.0000001)").should eq("0.0000001")
      document.xpath_float("number('  12  ')").should eq(12.0)
      document.xpath_float("number('1e3')").nan?.should be_true
      document.xpath_bool("boolean('')").should be_false
      document.xpath_bool("true() and not(false())").should be_true
    end

    it "binds variables" do
      document = Mica.parse(DOC)
      variables = {"wanted" => "2"} of String => Mica::XPath::Value
      document.xpath_nodes("//a[@id = $wanted]", variables: variables).size.should eq(1)
      expect_raises(Mica::XPathError, /Undefined XPath variable/) { document.xpath("$missing") }
    end

    it "reuses a compiled expression" do
      expression = Mica::XPath.compile("count(//b)")
      expression.evaluate(Mica.parse(DOC).node).should eq(3.0)
      expression.evaluate(Mica.parse("<x><b/></x>").node).should eq(1.0)
    end
  end

  describe "errors" do
    it "rejects syntax errors and unsupported features" do
      document = Mica.parse(DOC)
      ["//a[", "//a]", "", "1 +", "//@", "foo(", "unknown()", "id('x')", "lang('en')", "namespace::*", "//a/b/'x'", "'unterminated"].each do |path|
        expect_raises(Mica::XPathError) { document.xpath(path) }
      end
    end

    it "raises when a typed accessor gets the wrong result type" do
      expect_raises(Mica::XPathError) { Mica.parse(DOC).xpath_nodes("count(//a)") }
    end

    it "bounds expression nesting" do
      expect_raises(Mica::XPathError, /nested too deeply/) { Mica.parse(DOC).xpath("(" * 500 + "1" + ")" * 500) }
    end
  end
end
