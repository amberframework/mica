require "json"
require "../xml"

module Mica::XML
  # Reads an XML document into the same field hash a JSON object body
  # produces, so one schema can validate either format. Web frameworks use
  # it as a request-body parser; it is opt-in (`require "mica/xml/fields"`)
  # because it pulls in stdlib `JSON`.
  #
  # The root element stands for the JSON object itself, so its name is not
  # a key. Each child element becomes a field named by its local name:
  #
  # - an element with only text becomes a string (`<name>Ada</name>` gives
  #   `"name" => "Ada"`, and an empty element gives `""`);
  # - an element with attributes or child elements becomes a nested object;
  # - a name that repeats among siblings becomes an array, in document order;
  # - attributes become `"@name"` keys of their element's object;
  # - text mixed in among child elements becomes a `"#text"` key, with the
  #   surrounding white space removed, when it is not only white space.
  #
  # Values stay strings; the schema converts them, as it does for form data.
  #
  # ```
  # require "mica/xml/fields"
  #
  # Mica::XML::Fields.read(%(<user id="7"><name>Ada</name><role>admin</role><role>dev</role></user>))
  # # => {"@id" => "7", "name" => "Ada", "role" => ["admin", "dev"]}
  # ```
  module Fields
    # Parser options for request bodies: the secure defaults, with element
    # nesting capped at 64 levels, which no real form or API payload
    # approaches.
    REQUEST_BODY_OPTIONS = ParserOptions.new(max_element_depth: 64)

    # Parses *source* and returns its fields. Raises the same errors as
    # `Mica::XML.parse` (`Mica::ParseError`, `Mica::LimitExceededError`,
    # `Mica::EncodingError`) when the body is not well-formed or trips a
    # limit. A document without a root element cannot be parsed, so every
    # result comes from a root element.
    def self.read(source : String | Bytes | IO, options : ParserOptions = REQUEST_BODY_OPTIONS) : Hash(String, JSON::Any)
      document = XML.parse(source, options)
      root = document.root
      return {} of String => JSON::Any unless root

      fields_of(root)
    end

    private def self.fields_of(element : Node) : Hash(String, JSON::Any)
      fields = {} of String => JSON::Any
      element.attributes.each do |attribute|
        fields["@#{attribute.name}"] = JSON::Any.new(attribute.content)
      end

      values_by_child_name = {} of String => Array(JSON::Any)
      mixed_text = String::Builder.new
      element.children.each do |child|
        if child.element?
          (values_by_child_name[child.name] ||= [] of JSON::Any) << value_of(child)
        elsif child.text? || child.cdata?
          mixed_text << child.content
        end
      end

      values_by_child_name.each do |child_name, values|
        fields[child_name] = values.size == 1 ? values.first : JSON::Any.new(values)
      end

      text = mixed_text.to_s.strip
      fields["#text"] = JSON::Any.new(text) unless text.empty?
      fields
    end

    # An element is a plain string field when it carries no attributes and
    # no child elements; otherwise it is a nested object.
    private def self.value_of(element : Node) : JSON::Any
      has_child_elements = element.children.any?(&.element?)
      if element.attributes.empty? && !has_child_elements
        JSON::Any.new(element.content)
      else
        JSON::Any.new(fields_of(element))
      end
    end
  end
end
