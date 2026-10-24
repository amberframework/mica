require "../spec_helper"

private def elapsed(&) : Time::Span
  started = Time.instant
  yield
  Time.instant - started
end

describe "Mica security defaults" do
  it "stops the billion laughs attack quickly" do
    lol = String.build do |io|
      io << %(<?xml version="1.0"?><!DOCTYPE lolz [<!ENTITY lol "lol">)
      (1..9).each { |level| io << %(<!ENTITY lol#{level} ") << "&lol#{level == 1 ? "" : level - 1};" * 10 << %(">) }
      io << %(]><lolz>&lol9;</lolz>)
    end
    time = elapsed do
      expect_raises(Mica::LimitExceededError, /max_entity_expansions/) { Mica.parse(lol) }
    end
    time.should be < 1.second
  end

  it "stops the billion laughs attack inside attribute values" do
    lol = String.build do |io|
      io << %(<!DOCTYPE lolz [<!ENTITY lol "lol">)
      (1..9).each { |level| io << %(<!ENTITY lol#{level} ") << "&lol#{level == 1 ? "" : level - 1};" * 10 << %(">) }
      io << %(]><lolz a="&lol9;"/>)
    end
    expect_raises(Mica::LimitExceededError) { Mica.parse(lol) }
  end

  it "stops the quadratic blowup attack quickly" do
    big = "x" * 100_000
    xml = %(<!DOCTYPE r [<!ENTITY a "#{big}">]><r>#{"&a;" * 50_000}</r>)
    time = elapsed do
      expect_raises(Mica::LimitExceededError, /max_entity_expansion_bytes/) { Mica.parse(xml) }
    end
    time.should be < 1.second
  end

  it "charges DTD default attributes against the expansion budget" do
    xml = %(<!DOCTYPE r [<!ATTLIST e d CDATA "#{"x" * 1000}">]><r>#{"<e/>" * 2000}</r>)
    options = Mica::ParserOptions.new(max_entity_expansion_bytes: 100_000)
    expect_raises(Mica::LimitExceededError) { Mica.parse(xml, options) }
  end

  it "limits element nesting depth without recursion" do
    deep = "<a>" * 2000 + "</a>" * 2000
    expect_raises(Mica::LimitExceededError, /max_element_depth/) { Mica.parse(deep) }
    Mica.parse(deep, Mica::ParserOptions.new(max_element_depth: 2000)).root.should_not be_nil
  end

  it "limits entity nesting depth" do
    entities = (1..30).map { |level| %(<!ENTITY e#{level} "&e#{level + 1};">) }.join + %(<!ENTITY e31 "x">)
    expect_raises(Mica::LimitExceededError, /max_entity_depth/) { Mica.parse(%(<!DOCTYPE r [#{entities}]><r>&e1;</r>)) }
  end

  it "limits attributes per element, name length, token size and input size" do
    many = "<a " + (1..20).map { |index| %(a#{index}="1") }.join(' ') + "/>"
    expect_raises(Mica::LimitExceededError) { Mica.parse(many, Mica::ParserOptions.new(max_attributes: 10)) }
    expect_raises(Mica::LimitExceededError) { Mica.parse("<#{"n" * 200}/>", Mica::ParserOptions.new(max_name_bytes: 100)) }
    expect_raises(Mica::LimitExceededError) { Mica.parse("<a>#{"t" * 5000}</a>", Mica::ParserOptions.new(max_token_bytes: 1000)) }
    expect_raises(Mica::LimitExceededError) do
      Mica.parse(IO::Memory.new("<a>#{"t" * 300_000}</a>"), Mica::ParserOptions.new(max_token_bytes: 1000))
    end
    expect_raises(Mica::LimitExceededError) do
      Mica.parse(IO::Memory.new("<a>#{"<b/>" * 100_000}</a>"), Mica::ParserOptions.new(max_input_bytes: 10_000_i64))
    end
  end

  it "never reads external DTDs or entities" do
    secret = File.tempname("mica-secret", ".txt")
    File.write(secret, "TOP-SECRET")
    begin
      xml = %(<!DOCTYPE r SYSTEM "file://#{secret}" [<!ENTITY s SYSTEM "file://#{secret}"><!ENTITY % p SYSTEM "file://#{secret}">%p;]><r>&s;</r>)
      document = Mica.parse(xml)
      document.to_xml.should_not contain("TOP-SECRET")
      root_of(document).content.should eq("")
    ensure
      File.delete(secret)
    end
  end

  it "seeds name hashing per table" do
    Mica::NameTable.new.intern("x").should eq(Mica::NameTable.new.intern("x"))
  end
end
