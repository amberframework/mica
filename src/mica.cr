# Mica is a pure-Crystal XML 1.0 + Namespaces library: a streaming
# `Mica::Reader`, a DOM (`Mica::Document`, `Mica::Node`), a writer
# (`Mica::Builder`) and an XPath 1.0 subset (`Mica::XPath`). It needs no C
# library, never touches the network or file system while parsing, and is
# secure by default (see `Mica::ParserOptions`).
module Mica
  VERSION = {{ `shards version "#{__DIR__}"`.chomp.stringify }}

  # Parses *source* (a `String`, `Bytes` or `IO`) into a `Mica::Document`.
  #
  # ```
  # document = Mica.parse(%(<list><item id="1">one</item></list>))
  # document.root.try(&.first_element_child.try(&.["id"])) # => "1"
  # ```
  #
  # Raises `Mica::ParseError` (with line and column) when the input is not
  # well-formed, `Mica::LimitExceededError` when a safety limit trips and
  # `Mica::EncodingError` for an unsupported or invalid encoding.
  def self.parse(source : String | Bytes | IO, options : ParserOptions = ParserOptions.default) : Document
    Document.parse(source, options)
  end
end

require "./mica/error"
require "./mica/parser_options"
require "./mica/char_class"
require "./mica/name_table"
require "./mica/utf16_decoder"
require "./mica/dtd"
require "./mica/reader"
require "./mica/escape"
require "./mica/node"
require "./mica/node_set"
require "./mica/attributes"
require "./mica/namespace"
require "./mica/document"
require "./mica/serializer"
require "./mica/builder"
require "./mica/xpath"
