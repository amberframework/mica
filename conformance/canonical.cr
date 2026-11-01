# Writes James Clark's canonical XML form used by the xmlconf OUTPUT files:
# no declaration, DOCTYPE or comments; attributes sorted by name; empty
# elements as start and end tag; character data with `&`, `<`, `>`, `"`,
# TAB, LF and CR escaped; PIs as `<?target data?>`. For an XML 1.1
# document the output starts with `<?xml version="1.1"?>` and every C0 and
# C1 control character (and DEL) is written as a decimal character
# reference, as in the eduni and IBM XML 1.1 OUTPUT files.
module Canonical
  def self.write(document : Mica::XML::Document) : String
    xml11 = document.version == "1.1"
    String.build do |io|
      io << %(<?xml version="1.1"?>) if xml11
      document.node.children.each { |child| write_node(io, child, xml11) }
    end
  end

  private def self.write_node(io : IO, node : Mica::XML::Node, xml11 : Bool) : Nil
    case node.type
    when .element_node?
      io << '<' << node.qualified_name
      attributes = [] of {String, String}
      node.each_attribute_index(include_declarations: true) do |index|
        attribute = node.document.node_at(index)
        attributes << {attribute.qualified_name, attribute.content}
      end
      attributes.sort_by!(&.[0])
      attributes.each do |name, value|
        io << ' ' << name << "=\""
        escape(io, value, xml11)
        io << '"'
      end
      io << '>'
      node.children.each { |child| write_node(io, child, xml11) }
      io << "</" << node.qualified_name << '>'
    when .text_node?, .cdata_section_node?
      escape(io, node.content, xml11)
    when .pi_node?
      io << "<?" << node.name << ' ' << node.content << "?>"
    when .entity_ref_node?
      io << "&" << node.name << ";"
    when .dtd_node?
      write_notations(io, node)
    end
  end

  # Second canonical form: a DOCTYPE listing the declared notations.
  private def self.write_notations(io : IO, node : Mica::XML::Node) : Nil
    notations = node.document.dtd.notations
    return if notations.empty?
    io << "<!DOCTYPE " << node.name << " [\n"
    notations.keys.sort!.each do |name|
      public_id, system_id = notations[name]
      io << "<!NOTATION " << name
      if public_id
        io << " PUBLIC '" << public_id << '\''
        io << " '" << system_id << '\'' if system_id
      else
        io << " SYSTEM '" << system_id << '\''
      end
      io << ">\n"
    end
    io << "]>\n"
  end

  private def self.escape(io : IO, text : String, xml11 : Bool) : Nil
    text.each_char do |char|
      case char
      when '&'  then io << "&amp;"
      when '<'  then io << "&lt;"
      when '>'  then io << "&gt;"
      when '"'  then io << "&quot;"
      when '\t' then io << "&#9;"
      when '\n' then io << "&#10;"
      when '\r' then io << "&#13;"
      else
        if xml11 && (char.ord < 0x20 || (0x7F..0x9F).includes?(char.ord))
          io << "&#" << char.ord << ';'
        else
          io << char
        end
      end
    end
  end
end
