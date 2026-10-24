module Mica
  # Options for one parse: namespace processing and the safety limits.
  #
  # Every parse is secure by default. External DTD subsets and external
  # entities are never fetched (the library has no network or file access),
  # and the limits below stop entity-expansion and nesting attacks early.
  #
  # ```
  # options = Mica::ParserOptions.new(max_element_depth: 64)
  # document = Mica.parse(xml, options)
  # ```
  struct ParserOptions
    # Processes Namespaces in XML 1.0 (prefix binding, QName syntax).
    getter? namespace_aware : Bool
    # Maximum number of entity references expanded in one document.
    getter max_entity_expansions : Int32
    # Maximum total bytes produced by entity expansion and DTD attribute
    # defaults in one document.
    getter max_entity_expansion_bytes : Int64
    # Maximum nesting of entity references inside entity replacement text.
    getter max_entity_depth : Int32
    # Maximum element nesting depth.
    getter max_element_depth : Int32
    # Maximum length in bytes of a single name (element, attribute, entity, PI target).
    getter max_name_bytes : Int32
    # Maximum number of attributes on one element.
    getter max_attributes : Int32
    # Maximum size in bytes of one token: a text node, attribute value,
    # comment, PI, CDATA section or the internal DTD subset.
    getter max_token_bytes : Int32
    # Maximum size in bytes of the whole input (decoded), or nil for no cap.
    getter max_input_bytes : Int64?

    def initialize(
      @namespace_aware : Bool = true,
      @max_entity_expansions : Int32 = 10_000,
      @max_entity_expansion_bytes : Int64 = 16_i64 * 1024 * 1024,
      @max_entity_depth : Int32 = 16,
      @max_element_depth : Int32 = 1024,
      @max_name_bytes : Int32 = 50_000,
      @max_attributes : Int32 = 10_000,
      @max_token_bytes : Int32 = 10 * 1024 * 1024,
      @max_input_bytes : Int64? = nil,
    )
    end

    # Returns the default options.
    def self.default : self
      new
    end
  end
end
