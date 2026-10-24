module Mica
  # Writes XML to an `IO`, escaping text and attribute values and checking
  # names and characters so the output is always well-formed. The API
  # mirrors stdlib `XML::Builder`.
  #
  # ```
  # string = Mica.build(indent: 2) do |xml|
  #   xml.element("feed", lang: "en") do
  #     xml.element("title") { xml.text "Tom & Jerry" }
  #   end
  # end
  # string # => "<?xml version=\"1.0\"?>\n<feed lang=\"en\">\n  <title>Tom &amp; Jerry</title>\n</feed>\n"
  # ```
  #
  # Misuse (an attribute after content, an end without a start, an invalid
  # name or character) raises `Mica::BuilderError`.
  class Builder
    private enum State
      Content
      StartTagOpen
      AttributeOpen
      CdataOpen
      CommentOpen
      DTDOpen
    end

    private class Frame
      getter name : String
      getter binding_mark : Int32
      property? has_children : Bool = false
      property? has_text : Bool = false

      def initialize(@name : String, @binding_mark : Int32)
      end
    end

    @state = State::Content
    @frames = [] of Frame
    @bindings = [] of {String?, String}
    @indent_text = ""
    @quote_char = '"'
    @document_started = false
    @root_written = false
    @top_level_written = false

    def initialize(@io : IO)
    end

    # Sets the indentation string; empty disables indentation.
    def indent=(text : String) : String
      @indent_text = text
    end

    # Sets indentation to *level* spaces.
    def indent=(level : Int) : Int
      @indent_text = " " * level
      level
    end

    # Sets the quote used around attribute values (`'"'` or `'\''`).
    def quote_char=(char : Char) : Char
      unless char == '"' || char == '\''
        raise BuilderError.new("Quote character must be '\"' or '\\''")
      end
      @quote_char = char
    end

    # Writes the XML declaration.
    def start_document(version : String? = nil, encoding : String? = nil) : Nil
      raise BuilderError.new("start_document must come first") if @document_started || @top_level_written
      @document_started = true
      @io << %(<?xml version=") << (version || "1.0") << '"'
      if encoding
        unless encoding.compare("UTF-8", case_insensitive: true) == 0
          raise BuilderError.new("Mica::Builder writes UTF-8 only, not #{encoding}")
        end
        @io << %( encoding=") << encoding << '"'
      end
      @io << "?>\n"
    end

    # Closes every open element and ends the document with a newline.
    def end_document : Nil
      close_start_tag
      until @frames.empty?
        end_element
      end
      @io << '\n' if @top_level_written
      flush
    end

    # Writes a whole document: the declaration, the block's content and the
    # final newline.
    def document(version : String? = nil, encoding : String? = nil, &) : Nil
      start_document(version, encoding)
      yield
      end_document
    end

    # Opens element *name*.
    def start_element(name : String) : Nil
      Escape.check_name(name)
      open_element(name)
    end

    # Opens element *prefix*:*name*, declaring *namespace_uri* for the
    # prefix when it is not already in scope.
    def start_element(prefix : String?, name : String, namespace_uri : String?) : Nil
      Escape.check_name(name)
      Escape.check_name(prefix) if prefix
      open_element(prefix ? "#{prefix}:#{name}" : name)
      declare_if_needed(prefix, namespace_uri) if namespace_uri
    end

    private def open_element(qualified_name : String) : Nil
      ensure_content_state("start an element")
      close_start_tag
      if parent = @frames.last?
        parent.has_children = true
        write_indent(@frames.size) unless parent.has_text?
      else
        raise BuilderError.new("A document has one root element") if @root_written && @document_started
        @io << '\n' if @top_level_written && !@indent_text.empty?
        @root_written = true
      end
      @top_level_written = true
      @io << '<' << qualified_name
      @frames << Frame.new(qualified_name, @bindings.size)
      @state = State::StartTagOpen
    end

    # Closes the innermost open element.
    def end_element : Nil
      frame = @frames.pop? || raise BuilderError.new("end_element without an open element")
      case @state
      when .start_tag_open?
        @io << "/>"
      when .content?
        if frame.has_children? && !frame.has_text?
          write_indent(@frames.size)
        end
        @io << "</" << frame.name << '>'
      else
        raise BuilderError.new("end_element while #{@state} is open")
      end
      @state = State::Content
      @bindings.pop(@bindings.size - frame.binding_mark)
    end

    # Writes element *name* with *attributes* around the block's content.
    def element(__name__ : String, **attributes, &)
      start_element(__name__)
      self.attributes(attributes)
      result = yield
      end_element
      result
    end

    # :ditto:
    def element(__name__ : String, attributes : Hash | NamedTuple, &)
      start_element(__name__)
      self.attributes(attributes)
      result = yield
      end_element
      result
    end

    # Writes an empty element *name* with *attributes*.
    def element(__name__ : String, **attributes) : Nil
      element(__name__, attributes)
    end

    # :ditto:
    def element(name : String, attributes : Hash | NamedTuple) : Nil
      start_element(name)
      self.attributes(attributes)
      end_element
    end

    # Writes element *prefix*:*name* in *namespace_uri* around the block.
    def element(__prefix__ : String?, __name__ : String, __namespace_uri__ : String?, **attributes, &)
      start_element(__prefix__, __name__, __namespace_uri__)
      self.attributes(attributes)
      result = yield
      end_element
      result
    end

    # Writes an empty element *prefix*:*name* in *namespace_uri*.
    def element(prefix : String?, name : String, namespace_uri : String?, **attributes) : Nil
      start_element(prefix, name, namespace_uri)
      self.attributes(attributes)
      end_element
    end

    # Writes attribute *name* with *value* on the open start tag.
    def attribute(name : String, value) : Nil
      Escape.check_name(name)
      write_attribute(name, value.to_s)
    end

    # Writes attribute *prefix*:*name* in *namespace_uri*.
    def attribute(prefix : String?, name : String, namespace_uri : String?, value) : Nil
      Escape.check_name(name)
      Escape.check_name(prefix) if prefix
      declare_if_needed(prefix, namespace_uri) if prefix && namespace_uri
      write_attribute(prefix ? "#{prefix}:#{name}" : name, value.to_s)
    end

    # Opens attribute *name*; write its value with `text`, then call
    # `end_attribute`.
    def start_attribute(name : String) : Nil
      Escape.check_name(name)
      require_start_tag("start an attribute")
      @io << ' ' << name << '=' << @quote_char
      @state = State::AttributeOpen
    end

    # Ends the open attribute.
    def end_attribute : Nil
      raise BuilderError.new("end_attribute without start_attribute") unless @state.attribute_open?
      @io << @quote_char
      @state = State::StartTagOpen
    end

    # Writes each pair of *attributes*.
    def attributes(attributes : Hash | NamedTuple) : Nil
      attributes.each { |name, value| attribute(name.to_s, value) }
    end

    # :ditto:
    def attributes(**attributes) : Nil
      attributes(attributes)
    end

    # Declares namespace *uri* for *prefix* (nil for the default namespace)
    # on the open start tag.
    def namespace(prefix : String?, uri : String) : Nil
      Escape.check_name(prefix) if prefix
      write_attribute(prefix ? "xmlns:#{prefix}" : "xmlns", uri)
      @bindings << {prefix, uri}
    end

    # Writes escaped character data. Inside `start_attribute`, `start_cdata`
    # or `start_comment` it writes to that construct instead.
    def text(content : String) : Nil
      Escape.check_text(content)
      case @state
      when .attribute_open?
        Escape.attribute(@io, content.to_slice, @quote_char)
      when .cdata_open?
        @io << content.gsub("]]>", "]]]]><![CDATA[>")
      when .comment_open?
        check_comment(content)
        @io << content
      when .dtd_open?
        raise BuilderError.new("text is not allowed inside a DTD")
      else
        close_start_tag
        frame = @frames.last? || raise BuilderError.new("Text must be inside an element")
        frame.has_text = true
        Escape.text(@io, content.to_slice)
      end
    end

    # Opens a CDATA section.
    def start_cdata : Nil
      start_child_construct("start a CDATA section")
      @io << "<![CDATA["
      @state = State::CdataOpen
    end

    # Closes the CDATA section.
    def end_cdata : Nil
      raise BuilderError.new("end_cdata without start_cdata") unless @state.cdata_open?
      @io << "]]>"
      @state = State::Content
    end

    # Writes a CDATA section around the block's text.
    def cdata(&) : Nil
      start_cdata
      yield
      end_cdata
    end

    # Writes *text* as a CDATA section (a `]]>` inside is split).
    def cdata(text : String) : Nil
      cdata { self.text(text) }
    end

    # Opens a comment.
    def start_comment : Nil
      ensure_content_state("start a comment")
      close_start_tag
      if frame = @frames.last?
        frame.has_children = true
        write_indent(@frames.size) unless frame.has_text?
      else
        @top_level_written = true
      end
      @io << "<!--"
      @state = State::CommentOpen
    end

    # Closes the comment.
    def end_comment : Nil
      raise BuilderError.new("end_comment without start_comment") unless @state.comment_open?
      @io << "-->"
      @state = State::Content
    end

    # Writes a comment around the block's text.
    def comment(&) : Nil
      start_comment
      yield
      end_comment
    end

    # Writes *text* as a comment. Raises when it contains `--` or ends
    # with `-`.
    def comment(text : String) : Nil
      comment { self.text(text) }
    end

    # Opens a DOCTYPE declaration.
    def start_dtd(name : String, pubid : String?, sysid : String?) : Nil
      Escape.check_name(name)
      raise BuilderError.new("A DOCTYPE must come before the root element") if @root_written
      ensure_content_state("start a DTD")
      @io << "<!DOCTYPE " << name
      if pubid
        raise BuilderError.new("A public identifier needs a system identifier") unless sysid
        @io << %( PUBLIC ") << pubid << %(" ") << sysid << '"'
      elsif sysid
        @io << %( SYSTEM ") << sysid << '"'
      end
      @top_level_written = true
      @state = State::DTDOpen
    end

    # Closes the DOCTYPE declaration.
    def end_dtd : Nil
      raise BuilderError.new("end_dtd without start_dtd") unless @state.dtd_open?
      @io << '>'
      @state = State::Content
    end

    # Writes a DOCTYPE declaration with an optional raw internal *subset*.
    def dtd(name : String, pubid : String?, sysid : String?, subset : String? = nil) : Nil
      start_dtd(name, pubid, sysid)
      @io << " [" << subset << ']' if subset
      end_dtd
    end

    # Writes a DOCTYPE declaration around the block.
    def dtd(name : String, pubid : String?, sysid : String?, &) : Nil
      start_dtd(name, pubid, sysid)
      yield
      end_dtd
    end

    # :nodoc:
    def open_element_count : Int32
      @frames.size
    end

    # Flushes the underlying IO.
    def flush : Nil
      @io.flush
    end

    private def write_attribute(name : String, value : String) : Nil
      require_start_tag("write an attribute")
      Escape.check_text(value)
      @io << ' ' << name << '=' << @quote_char
      Escape.attribute(@io, value.to_slice, @quote_char)
      @io << @quote_char
    end

    private def declare_if_needed(prefix : String?, uri : String) : Nil
      bound = @bindings.reverse_each.find { |binding| binding[0] == prefix }
      return if bound && bound[1] == uri
      namespace(prefix, uri)
    end

    private def require_start_tag(action : String) : Nil
      return if @state.start_tag_open?
      raise BuilderError.new("Cannot #{action}: no start tag is open")
    end

    private def ensure_content_state(action : String) : Nil
      return if @state.content? || @state.start_tag_open?
      raise BuilderError.new("Cannot #{action} while #{@state} is open")
    end

    private def start_child_construct(action : String) : Nil
      ensure_content_state(action)
      close_start_tag
      frame = @frames.last? || raise BuilderError.new("Cannot #{action} outside an element")
      frame.has_text = true
    end

    private def close_start_tag : Nil
      return unless @state.start_tag_open?
      @io << '>'
      @state = State::Content
    end

    private def write_indent(level : Int32) : Nil
      return if @indent_text.empty?
      @io << '\n'
      level.times { @io << @indent_text }
    end

    private def check_comment(text : String) : Nil
      if text.includes?("--") || text.ends_with?('-')
        raise BuilderError.new("A comment cannot contain '--' or end with '-'")
      end
    end
  end

  # Builds an XML document and returns it as a string. See `Mica::Builder`.
  def self.build(version : String? = nil, encoding : String? = nil, indent = nil, quote_char : Char? = nil, &) : String
    String.build do |io|
      build(io, version, encoding, indent, quote_char) { |xml| yield xml }
    end
  end

  # Builds an XML fragment (no declaration) and returns it as a string.
  def self.build_fragment(*, indent = nil, quote_char : Char? = nil, &) : String
    String.build do |io|
      build_fragment(io, indent: indent, quote_char: quote_char) { |xml| yield xml }
    end
  end

  # Builds an XML document into *io*.
  def self.build(io : IO, version : String? = nil, encoding : String? = nil, indent = nil, quote_char : Char? = nil, &) : Nil
    xml = Builder.new(io)
    configure_builder(xml, indent, quote_char)
    xml.start_document(version, encoding)
    yield xml
    xml.end_document
  end

  # Builds an XML fragment into *io*.
  def self.build_fragment(io : IO, *, indent = nil, quote_char : Char? = nil, &) : Nil
    xml = Builder.new(io)
    configure_builder(xml, indent, quote_char)
    yield xml
    until xml.open_element_count == 0
      xml.end_element
    end
    xml.flush
  end

  private def self.configure_builder(xml : Builder, indent, quote_char : Char?) : Nil
    xml.indent = indent if indent
    xml.quote_char = quote_char if quote_char
  end
end
