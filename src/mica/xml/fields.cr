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
  # A request body is untrusted, so `read` streams it once through
  # `Mica::XML::Reader` (no DOM is built) and raises
  # `Fields::RejectedDocumentError` at the first sign of what a field hash
  # cannot carry faithfully or safely: a document type declaration (DTD),
  # sibling elements or attributes that share a local name but not a
  # namespace, or nesting deeper than `MAX_DEPTH`. Every event and every
  # copied byte is charged to the parse's work meter, so the whole read
  # stays linear in the body's size.
  #
  # ```
  # require "mica/xml/fields"
  #
  # Mica::XML::Fields.read(%(<user id="7"><name>Ada</name><role>admin</role><role>dev</role></user>))
  # # => {"@id" => "7", "name" => "Ada", "role" => ["admin", "dev"]}
  # ```
  module Fields
    # The deepest element nesting `read` accepts, whatever options it is
    # given. The root element is depth 1.
    MAX_DEPTH = 64

    # The largest body `read` accepts with its default options.
    MAX_BODY_BYTES = 1_i64 * 1024 * 1024

    # Parser options for request bodies: the secure defaults, with nesting
    # capped at `MAX_DEPTH` and the body capped at `MAX_BODY_BYTES`.
    REQUEST_BODY_OPTIONS = ParserOptions.new(max_element_depth: MAX_DEPTH, max_input_bytes: MAX_BODY_BYTES)

    private XMLNS_NAMESPACE = "http://www.w3.org/2000/xmlns/"

    # Raised when a well-formed document is refused as a request body: it
    # declares a DTD, its names collide across namespaces, or it nests
    # deeper than `MAX_DEPTH`.
    class RejectedDocumentError < Mica::Error
    end

    # Parses *source* and returns its fields. Raises the errors of
    # `Mica::XML::Reader` (`Mica::ParseError`, `Mica::LimitExceededError`,
    # `Mica::EncodingError`) when the body is not well-formed or trips a
    # limit, the work budget or the deadline, and `RejectedDocumentError` as
    # described on `Fields`. *options* must cap `max_input_bytes`, because a
    # request body always needs a size limit; `ArgumentError` otherwise.
    def self.read(source : String | Bytes | IO, options : ParserOptions = REQUEST_BODY_OPTIONS) : Hash(String, JSON::Any)
      unless options.max_input_bytes
        raise ArgumentError.new("Request-body options must set max_input_bytes")
      end

      Conversion.new(Reader.new(source, options)).perform
    end

    # One element being read: its attributes, its child values grouped by
    # local name, and its own text.
    private class OpenElement
      getter local_name : String
      getter namespace_uri : String?
      getter attribute_fields = {} of String => JSON::Any
      getter child_values_by_name = {} of String => Array(JSON::Any)
      getter child_namespace_by_name = {} of String => String?
      getter text = String::Builder.new

      def initialize(@local_name : String, @namespace_uri : String?)
      end

      def has_child_elements? : Bool
        !child_values_by_name.empty?
      end
    end

    # One streaming pass over a reader, charged to the reader's meter.
    private struct Conversion
      def initialize(@reader : Reader)
      end

      def perform : Hash(String, JSON::Any)
        open_elements = [] of OpenElement
        root_fields = {} of String => JSON::Any

        while @reader.read
          @reader.charge(1)
          case @reader.node_type
          when .document_type?
            reject("A request body cannot declare a document type (DTD)")
          when .entity_reference?
            reject("A request body cannot contain entity references")
          when .element?
            if open_elements.size >= MAX_DEPTH
              reject("A request body cannot nest elements deeper than #{MAX_DEPTH} levels")
            end
            element = open_element
            if @reader.empty_element?
              root_fields = close(element, open_elements) || root_fields
            else
              open_elements << element
            end
          when .end_element?
            element = open_elements.pop
            root_fields = close(element, open_elements) || root_fields
          when .text?, .cdata?, .significant_whitespace?
            if parent = open_elements.last?
              value = @reader.value
              @reader.charge(value.bytesize)
              parent.text << value
            end
          end
        end

        root_fields
      end

      private def open_element : OpenElement
        element = OpenElement.new(@reader.local_name, @reader.namespace_uri)
        if @reader.move_to_first_attribute
          loop do
            add_attribute(element)
            break unless @reader.move_to_next_attribute
          end
          @reader.move_to_element
        end
        element
      end

      private def add_attribute(element : OpenElement) : Nil
        @reader.charge(1)
        # Namespace declarations bind prefixes; they are not data.
        return if @reader.namespace_uri == XMLNS_NAMESPACE || @reader.name == "xmlns"

        local_name = @reader.local_name
        key = "@#{local_name}"
        value = @reader.value
        @reader.charge(key.bytesize + value.bytesize)
        if element.attribute_fields.has_key?(key)
          reject("Two attributes share the local name #{Core.quote(local_name)} in different namespaces")
        end
        element.attribute_fields[key] = JSON::Any.new(value)
      end

      # Finishes *element*: hands its value to the parent, or returns the
      # root's fields when it is the root.
      private def close(element : OpenElement, open_elements : Array(OpenElement)) : Hash(String, JSON::Any)?
        parent = open_elements.last?
        return fields_of(element) unless parent

        value = if element.attribute_fields.empty? && !element.has_child_elements?
                  JSON::Any.new(element.text.to_s)
                else
                  JSON::Any.new(fields_of(element))
                end
        add_child(parent, element, value)
        nil
      end

      private def add_child(parent : OpenElement, element : OpenElement, value : JSON::Any) : Nil
        name = element.local_name
        if parent.child_namespace_by_name.has_key?(name)
          if parent.child_namespace_by_name[name] != element.namespace_uri
            reject("Sibling elements share the local name #{Core.quote(name)} in different namespaces")
          end
        else
          @reader.charge(name.bytesize)
          parent.child_namespace_by_name[name] = element.namespace_uri
        end
        (parent.child_values_by_name[name] ||= [] of JSON::Any) << value
      end

      private def fields_of(element : OpenElement) : Hash(String, JSON::Any)
        fields = element.attribute_fields
        element.child_values_by_name.each do |name, values|
          @reader.charge(values.size)
          fields[name] = values.size == 1 ? values.first : JSON::Any.new(values)
        end

        text = element.text.to_s
        text = text.strip if element.has_child_elements?
        fields["#text"] = JSON::Any.new(text) unless text.empty?
        fields
      end

      private def reject(message : String) : NoReturn
        raise RejectedDocumentError.new("#{message} (#{@reader.position})")
      end
    end
  end
end
