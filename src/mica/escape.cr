module Mica
  # :nodoc:
  #
  # Escaping and validation shared by the serializer and the builder.
  module Escape
    # Writes *bytes* as character data: `&`, `<`, `>` and CR become
    # references.
    def self.text(io : IO, bytes : Bytes) : Nil
      start = 0
      bytes.each_with_index do |byte, index|
        replacement = case byte
                      when '&'.ord then "&amp;"
                      when '<'.ord then "&lt;"
                      when '>'.ord then "&gt;"
                      when 0x0D    then "&#13;"
                      end
        next unless replacement
        io.write(bytes[start, index - start]) if index > start
        io << replacement
        start = index + 1
      end
      io.write(bytes[start, bytes.size - start]) if start < bytes.size
    end

    # Writes *bytes* as an attribute value delimited by *quote*: `&`, `<`,
    # `>`, the quote and TAB/LF/CR become references so that the value
    # survives attribute-value normalization unchanged.
    def self.attribute(io : IO, bytes : Bytes, quote : Char = '"') : Nil
      start = 0
      bytes.each_with_index do |byte, index|
        replacement = case byte
                      when '&'.ord  then "&amp;"
                      when '<'.ord  then "&lt;"
                      when '>'.ord  then "&gt;"
                      when '"'.ord  then quote == '"' ? "&quot;" : nil
                      when '\''.ord then quote == '\'' ? "&apos;" : nil
                      when 0x09     then "&#9;"
                      when 0x0A     then "&#10;"
                      when 0x0D     then "&#13;"
                      end
        next unless replacement
        io.write(bytes[start, index - start]) if index > start
        io << replacement
        start = index + 1
      end
      io.write(bytes[start, bytes.size - start]) if start < bytes.size
    end

    # Raises `Mica::Error` unless every character of *text* matches the XML
    # `Char` production (and the string is valid UTF-8).
    def self.check_text(text : String) : Nil
      raise Error.new("String is not valid UTF-8") unless text.valid_encoding?
      text.each_char do |char|
        unless CharClass.xml_char?(char.ord)
          raise Error.new("Character U+#{char.ord.to_s(16).upcase.rjust(4, '0')} is not allowed in XML")
        end
      end
    end

    # Raises `Mica::Error` unless *name* matches the XML `Name` production.
    def self.check_name(name : String) : Nil
      raise Error.new("Invalid XML name: #{name.inspect}") unless name?(name)
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
  end
end
