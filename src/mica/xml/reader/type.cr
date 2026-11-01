class Mica::XML::Reader
  # The kind of node the reader is positioned on. Values match libxml2's
  # `xmlReaderTypes` (and stdlib `XML::Reader::Type`).
  enum Type
    NONE                   =  0
    ELEMENT                =  1
    ATTRIBUTE              =  2
    TEXT                   =  3
    CDATA                  =  4
    ENTITY_REFERENCE       =  5
    PROCESSING_INSTRUCTION =  7
    COMMENT                =  8
    DOCUMENT_TYPE          = 10
    SIGNIFICANT_WHITESPACE = 14
    END_ELEMENT            = 15
  end
end
