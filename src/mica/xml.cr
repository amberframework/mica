require "./core"

# XML 1.0 (5th edition) and XML 1.1 (2nd edition) with Namespaces in XML: a
# streaming `Reader`, a DOM (`Document`, `Node`), a writer (`Builder`) and
# XPath 1.0 (`XPath`). The API follows stdlib `XML`; porting is mostly
# renaming the constant.
module Mica::XML
  # Parses *source* (a `String`, `Bytes` or `IO`) into a
  # `Mica::XML::Document`.
  #
  # ```
  # document = Mica::XML.parse(%(<list><item id="1">one</item></list>))
  # document.root.try(&.first_element_child.try(&.["id"])) # => "1"
  # ```
  #
  # Raises `Mica::ParseError` (with line, column and byte offset) when the
  # input is not well-formed, `Mica::LimitExceededError` when a safety
  # limit, the work budget or the deadline trips, and `Mica::EncodingError`
  # for an unsupported or invalid encoding. *meter* lets the parse share a
  # work budget with other operations (for example the queries that
  # follow it); without it the parse starts a meter from
  # `options.work_budget`.
  def self.parse(source : String | Bytes | IO, options : ParserOptions = ParserOptions.default, meter : Core::WorkMeter? = nil) : Document
    Document.parse(source, options, meter)
  end

  # Raised when an XPath expression cannot be parsed or evaluated.
  class XPathError < Mica::Error
  end

  # Raised when `Mica::XML::Builder` is used in a way that would produce
  # malformed XML (an invalid name, an illegal character, or out-of-order
  # calls).
  class BuilderError < Mica::Error
  end

  # Raised when `ParserOptions#check_normalization` is on and an XML 1.1
  # document is not fully normalized.
  class NormalizationError < Mica::ParseError
  end
end

require "./xml/parser_options"
require "./xml/char_class"
require "./xml/composing_characters"
require "./xml/name_table"
require "./xml/dtd"
require "./xml/reader"
require "./xml/escape"
require "./xml/node"
require "./xml/node_set"
require "./xml/attributes"
require "./xml/namespace"
require "./xml/document"
require "./xml/serializer"
require "./xml/builder"
require "./xml/xpath"
