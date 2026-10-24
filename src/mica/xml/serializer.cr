module Mica::XML
  # :nodoc:
  #
  # Writes DOM nodes as XML. The walk is iterative, so element depth is
  # bounded only by memory. Values of an XML 1.1 document are escaped with
  # the 1.1 rules (see `Escape.text`).
  struct Serializer
    # Indentation stops growing past this depth (as in libxml2), so
    # pretty-printed output stays linear in the number of nodes.
    MAX_INDENT_LEVELS = 64

    @xml11 = false

    def initialize(@io : IO, @indent : Int32, @indent_text : String)
    end

    def write(node : Node) : Nil
      document = node.document
      @xml11 = document.version == "1.1"
      case node.type
      when .document_node?
        write_document(document)
      when .element_node?
        write_tree(document, node.index)
      when .attribute_node?, .namespace_decl?
        write_attribute(document, node.index)
      else
        write_leaf(document, node.index)
      end
    end

    private def write_document(document : Document) : Nil
      @io << %(<?xml version=") << document.version << %(" encoding="UTF-8")
      @io << %( standalone="yes") if document.standalone?
      @io << "?>\n"
      child = document.data(0).first_child
      while child >= 0
        if document.kind(child).element_node?
          write_tree(document, child)
        else
          write_leaf(document, child)
        end
        @io << '\n'
        child = document.data(child).next_sibling
      end
    end

    private def write_tree(document : Document, root : Int32) : Nil
      format_stack = [] of Bool
      level = 0
      current = root
      loop do
        record = document.data(current)
        descended = false
        if record.kind.element_node?
          write_start_tag(document, current)
          first = record.first_child
          if first < 0
            @io << "/>"
          else
            @io << '>'
            formatted = @indent > 0 && formattable_children?(document, current)
            format_stack << formatted
            level += 1
            newline_indent(level) if formatted
            current = first
            descended = true
          end
        else
          write_leaf(document, current)
        end
        next if descended

        # Move to the next sibling, closing finished elements on the way up.
        loop do
          return if current == root
          following = document.data(current).next_sibling
          if following >= 0
            newline_indent(level) if format_stack.last
            current = following
            break
          end
          formatted = format_stack.pop
          level -= 1
          current = document.data(current).parent
          newline_indent(level) if formatted
          @io << "</" << document.names[document.data(current).name_id] << '>'
        end
      end
    end

    private def formattable_children?(document : Document, element : Int32) : Bool
      child = document.data(element).first_child
      while child >= 0
        kind = document.kind(child)
        return false if kind.text_node? || kind.cdata_section_node? || kind.entity_ref_node?
        child = document.data(child).next_sibling
      end
      true
    end

    private def newline_indent(level : Int32) : Nil
      @io << '\n'
      (Math.min(level, MAX_INDENT_LEVELS) * @indent).times { @io << @indent_text }
    end

    private def write_start_tag(document : Document, element : Int32) : Nil
      @io << '<' << document.names[document.data(element).name_id]
      attribute = document.data(element).first_attribute
      while attribute >= 0
        write_attribute(document, attribute)
        attribute = document.data(attribute).next_sibling
      end
    end

    private def write_attribute(document : Document, attribute : Int32) : Nil
      @io << ' ' << document.names[document.data(attribute).name_id] << %(=")
      Escape.attribute(@io, document.value_bytes(attribute), xml11: @xml11)
      @io << '"'
    end

    private def write_leaf(document : Document, index : Int32) : Nil
      record = document.data(index)
      case record.kind
      when .text_node?
        Escape.text(@io, document.value_bytes(index), @xml11)
      when .cdata_section_node?
        @io << "<![CDATA["
        Escape.cdata(@io, document.value_bytes(index))
        @io << "]]>"
      when .comment_node?
        @io << "<!--"
        @io.write(document.value_bytes(index))
        @io << "-->"
      when .pi_node?
        @io << "<?" << document.names[record.name_id]
        value = document.value_bytes(index)
        unless value.empty?
          @io << ' '
          @io.write(value)
        end
        @io << "?>"
      when .entity_ref_node?
        @io << '&' << document.names[record.name_id] << ';'
      when .dtd_node?
        write_doctype(document, record)
      end
    end

    private def write_doctype(document : Document, record : Document::NodeData) : Nil
      @io << "<!DOCTYPE " << document.names[record.name_id]
      public_id = document.public_id
      system_id = document.system_id
      if public_id
        @io << %( PUBLIC ") << public_id << '"'
        @io << %( ") << system_id << '"' if system_id
      elsif system_id
        quote = system_id.includes?('"') ? '\'' : '"'
        @io << " SYSTEM " << quote << system_id << quote
      end
      if subset = document.internal_subset
        @io << " [" << subset << ']'
      end
      @io << '>'
    end
  end
end
