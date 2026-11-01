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
  # - an element with only text becomes that text, exactly
  #   (`<name>Ada</name>` gives `"name" => "Ada"`; an empty element gives
  #   `""`);
  # - an element with attributes or child elements becomes a nested object;
  #   its own text is the `"#text"` key, kept exactly when it has no child
  #   elements, and with surrounding white space removed (and left out when
  #   blank) when the text is mixed in among child elements;
  # - a name that repeats among siblings becomes an array, in document order;
  # - attributes become `"@name"` keys of their element's object.
  #
  # Values stay strings; the schema converts them, as it does for form data.
  #
  # A request body is untrusted, so `read` refuses what a field hash cannot
  # carry faithfully or safely, raising `Fields::RejectedDocumentError`:
  # a document type declaration (DTD), sibling elements or attributes that
  # share a local name but not a namespace, and nesting deeper than
  # `MAX_DEPTH`. The parse and the conversion share one work budget, so the
  # whole read stays linear in the body's size.
  #
  # ```
  # require "mica/xml/fields"
  #
  # Mica::XML::Fields.read(%(<user id="7"><name>Ada</name><role>admin</role><role>dev</role></user>))
  # # => {"@id" => "7", "name" => "Ada", "role" => ["admin", "dev"]}
  # ```
  module Fields
    # The deepest element nesting `read` converts, whatever options it is
    # given: no form or API payload approaches it, and it keeps the
    # conversion's recursion far inside a fiber's stack.
    MAX_DEPTH = 64

    # The largest body `read` accepts with its default options.
    MAX_BODY_BYTES = 1_i64 * 1024 * 1024

    # Parser options for request bodies: the secure defaults, with nesting
    # capped at `MAX_DEPTH` and the body capped at `MAX_BODY_BYTES`.
    REQUEST_BODY_OPTIONS = ParserOptions.new(max_element_depth: MAX_DEPTH, max_input_bytes: MAX_BODY_BYTES)

    # Raised when a well-formed document is refused as a request body: it
    # declares a DTD, its names collide across namespaces, or it nests
    # deeper than `MAX_DEPTH`.
    class RejectedDocumentError < Mica::Error
    end

    # Parses *source* and returns its fields. Raises the errors of
    # `Mica::XML.parse` (`Mica::ParseError`, `Mica::LimitExceededError`,
    # `Mica::EncodingError`) when the body is not well-formed or trips a
    # limit, the work budget or the deadline, and `RejectedDocumentError` as
    # described on `Fields`.
    def self.read(source : String | Bytes | IO, options : ParserOptions = REQUEST_BODY_OPTIONS) : Hash(String, JSON::Any)
      meter = Core::WorkMeter.new(options.work_budget)
      document = XML.parse(source, options, meter)
      reject_document_type_declaration(document)
      root = document.root
      return {} of String => JSON::Any unless root

      Conversion.new(meter).fields_of(root, 1)
    end

    # Without a DTD there are no attribute defaults and no entities beyond
    # the five predefined ones, so the result can only hold what the body
    # spells out, and no reference is silently dropped.
    private def self.reject_document_type_declaration(document : Document) : Nil
      if document.node.children.any?(&.dtd?)
        raise RejectedDocumentError.new("A request body cannot declare a document type (DTD)")
      end
    end

    # One conversion, charged to the parse's work meter: one operation per
    # node visited plus the bytes of every key and value it copies.
    private struct Conversion
      def initialize(@meter : Core::WorkMeter)
      end

      def fields_of(element : Node, depth : Int32) : Hash(String, JSON::Any)
        if depth > MAX_DEPTH
          raise RejectedDocumentError.new("A request body cannot nest elements deeper than #{MAX_DEPTH} levels")
        end

        fields = {} of String => JSON::Any
        add_attributes(element, fields)

        children_by_name = {} of String => Array(Node)
        text = String::Builder.new
        element.children.each do |child|
          charge(1)
          if child.element?
            (children_by_name[child.name] ||= [] of Node) << child
          elsif child.text? || child.cdata?
            text << child.content
          end
        end

        children_by_name.each do |child_name, children|
          check_one_namespace(children, child_name)
          values = children.map { |child| value_of(child, depth + 1) }
          fields[child_name] = values.size == 1 ? values.first : JSON::Any.new(values)
        end

        add_text(fields, text.to_s, mixed: !children_by_name.empty?)
        fields
      end

      # An element is a plain string field when it carries no attributes
      # and no child elements; otherwise it is a nested object.
      private def value_of(element : Node, depth : Int32) : JSON::Any
        if element.attributes.empty? && element.children.none?(&.element?)
          content = element.content
          charge(content.bytesize)
          JSON::Any.new(content)
        else
          JSON::Any.new(fields_of(element, depth))
        end
      end

      private def add_attributes(element : Node, fields : Hash(String, JSON::Any)) : Nil
        element.attributes.each do |attribute|
          key = "@#{attribute.name}"
          value = attribute.content
          charge(1 + key.bytesize + value.bytesize)
          if fields.has_key?(key)
            raise RejectedDocumentError.new("Two attributes share the local name #{Core.quote(attribute.name)} in different namespaces")
          end
          fields[key] = JSON::Any.new(value)
        end
      end

      private def add_text(fields : Hash(String, JSON::Any), text : String, mixed : Bool) : Nil
        if mixed
          text = text.strip
          return if text.empty?
        elsif text.empty?
          return
        end
        charge(text.bytesize)
        fields["#text"] = JSON::Any.new(text)
      end

      private def check_one_namespace(children : Array(Node), child_name : String) : Nil
        namespace_uri = children.first.namespace_uri
        if children.any? { |child| child.namespace_uri != namespace_uri }
          raise RejectedDocumentError.new("Sibling elements share the local name #{Core.quote(child_name)} in different namespaces")
        end
      end

      private def charge(count : Int) : Nil
        @meter.enforce("while reading fields") { Core::Position.new(0_i64) } if @meter.charge(count)
      end
    end
  end
end
