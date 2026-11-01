struct Mica::XML::Node
  # The kind of a DOM node. Values match libxml2's `xmlElementType` (and
  # stdlib `XML::Node::Type`) for the kinds Mica produces.
  enum Type : UInt8
    NONE               =  0
    ELEMENT_NODE       =  1
    ATTRIBUTE_NODE     =  2
    TEXT_NODE          =  3
    CDATA_SECTION_NODE =  4
    ENTITY_REF_NODE    =  5
    PI_NODE            =  7
    COMMENT_NODE       =  8
    DOCUMENT_NODE      =  9
    DTD_NODE           = 14
    NAMESPACE_DECL     = 18
  end
end
