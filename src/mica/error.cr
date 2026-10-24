module Mica
  # Base class of every error the library raises. Rescue `Mica::Error` to
  # handle any parse, limit, encoding, XPath or builder failure.
  class Error < Exception
  end

  # Raised when the input is not well-formed XML 1.0 (or violates
  # Namespaces in XML 1.0 while namespace processing is on).
  #
  # *line_number* and *column_number* are 1-based. The column counts
  # characters from the start of the line.
  class ParseError < Error
    getter line_number : Int32
    getter column_number : Int32

    def initialize(message : String, @line_number : Int32, @column_number : Int32)
      super("#{message} (line #{@line_number}, column #{@column_number})")
    end
  end

  # Raised when a configured safety limit (entity expansion count or bytes,
  # entity nesting, element nesting, name length) is exceeded.
  class LimitExceededError < ParseError
  end

  # Raised when the document uses an encoding the library does not decode,
  # or when its bytes are not valid in the detected encoding.
  class EncodingError < ParseError
  end

  # Raised when an XPath expression cannot be parsed or evaluated.
  class XPathError < Error
  end

  # Raised when `Mica::Builder` is used in a way that would produce
  # malformed XML (an invalid name, an illegal character, or out-of-order
  # calls).
  class BuilderError < Error
  end
end
