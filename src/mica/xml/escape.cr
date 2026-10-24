module Mica::XML
  # :nodoc:
  #
  # Escaping and validation shared by the serializer and the builder.
  module Escape
    # Writes *bytes* as character data: `&`, `<`, `>` and CR become
    # references. With *xml11*, characters XML 1.1 forbids literally (the
    # restricted controls) and the line ends it would normalize (NEL, LSEP)
    # become character references too, so a value survives a round trip.
    def self.text(io : IO, bytes : Bytes, xml11 : Bool = false) : Nil
      write_escaped(io, bytes, xml11) do |byte|
        case byte
        when '&'.ord then "&amp;"
        when '<'.ord then "&lt;"
        when '>'.ord then "&gt;"
        when 0x0D    then "&#13;"
        end
      end
    end

    # Writes *bytes* as an attribute value delimited by *quote*: `&`, `<`,
    # `>`, the quote and TAB/LF/CR become references so that the value
    # survives attribute-value normalization unchanged. *xml11* as in
    # `text`.
    def self.attribute(io : IO, bytes : Bytes, quote : Char = '"', xml11 : Bool = false) : Nil
      write_escaped(io, bytes, xml11) do |byte|
        case byte
        when '&'.ord  then "&amp;"
        when '<'.ord  then "&lt;"
        when '>'.ord  then "&gt;"
        when '"'.ord  then quote == '"' ? "&quot;" : nil
        when '\''.ord then quote == '\'' ? "&apos;" : nil
        when 0x09     then "&#9;"
        when 0x0A     then "&#10;"
        when 0x0D     then "&#13;"
        end
      end
    end

    # Copies *bytes* to *io*, replacing each ASCII byte the block maps to a
    # string, and (with *xml11*) each XML 1.1 restricted character, NEL and
    # LSEP with a character reference. One pass over the bytes.
    private def self.write_escaped(io : IO, bytes : Bytes, xml11 : Bool, & : UInt8 -> String?) : Nil
      start = 0
      index = 0
      size = bytes.size
      while index < size
        byte = bytes[index]
        replacement = nil
        length = 1
        if byte < 0x80
          replacement = yield byte
          if replacement.nil? && xml11 && (byte == 0x7F || (byte < 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D))
            replacement = "&#x#{byte.to_s(16).upcase};"
          end
        elsif xml11
          code, length = Core::UTF8.decode(bytes[index, size - index])
          length = 1 if length == 0
          if (code >= 0x80 && code <= 0x9F) || code == 0x2028
            replacement = "&#x#{code.to_s(16).upcase};"
          end
        end
        if replacement
          io.write(bytes[start, index - start]) if index > start
          io << replacement
          start = index + length
        end
        index += length
      end
      io.write(bytes[start, size - start]) if start < size
    end

    # Raises `Mica::Error` unless *text* is valid UTF-8 and every character
    # is allowed in a document of that XML version: a `Char` for XML 1.0;
    # for XML 1.1 also the controls (written as character references).
    def self.check_text(text : String, xml11 : Bool = false) : Nil
      raise Error.new("String is not valid UTF-8") unless text.valid_encoding?
      text.each_char do |char|
        code = char.ord
        allowed = xml11 ? CharClass.xml11_char?(code) : CharClass.xml_char?(code)
        unless allowed
          raise Error.new("Character U+#{code.to_s(16).upcase.rjust(4, '0')} is not allowed in XML")
        end
      end
    end

    # Raises `Mica::Error` unless *name* matches the XML `Name` production.
    def self.check_name(name : String) : Nil
      raise Error.new("Invalid XML name: #{name.inspect}") unless name?(name)
    end

    # Returns true when *name* is a Namespaces QName: a Name with at most
    # one colon, neither first nor last, followed by a NameStartChar.
    def self.qname?(name : String) : Bool
      return false unless name?(name)
      colon = name.index(':')
      return true unless colon
      return false if colon == 0 || colon == name.size - 1 || name.index(':', colon + 1)
      CharClass.name_start_char?(name[colon + 1].ord)
    end

    # Returns true when *name* matches the XML `Name` production.
    def self.name?(name : String) : Bool
      return false if name.empty? || !name.valid_encoding?
      first = true
      name.each_char do |char|
        valid = first ? CharClass.name_start_char?(char.ord) : CharClass.name_char?(char.ord)
        return false unless valid
        first = false
      end
      true
    end

    # Writes CDATA content, splitting each `]]>` across two sections.
    def self.cdata(io : IO, bytes : Bytes) : Nil
      start = 0
      index = 0
      size = bytes.size
      while index + 2 < size
        if bytes[index] == ']'.ord && bytes[index + 1] == ']'.ord && bytes[index + 2] == '>'.ord
          io.write(bytes[start, index + 2 - start])
          io << "]]><![CDATA["
          start = index + 2
          index += 2
        else
          index += 1
        end
      end
      io.write(bytes[start, size - start]) if start < size
    end
  end
end
