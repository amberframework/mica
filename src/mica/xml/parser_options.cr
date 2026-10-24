module Mica::XML
  # Options for one parse: namespace processing, the safety limits and the
  # work budget.
  #
  # Every parse is secure by default. External DTD subsets and external
  # entities are never fetched (the library has no network or file access),
  # the limits below stop entity-expansion and nesting attacks early, and the
  # work budget stops any input that would make parsing do more than a
  # constant amount of work per byte.
  #
  # ```
  # options = Mica::XML::ParserOptions.new(max_element_depth: 64)
  # document = Mica::XML.parse(xml, options)
  # ```
  struct ParserOptions
    # The default work budget for parsing: 64 operations per byte read (or
    # expanded from an entity or a DTD default), plus 1,000,000, and at most
    # 60 seconds of wall-clock time. Legitimate documents use well under a
    # quarter of this allowance (see the README).
    DEFAULT_WORK_BUDGET = Core::WorkBudget.new(
      operations_per_unit: 64,
      base_operations: 1_000_000,
      timeout: 60.seconds,
    )

    # Processes Namespaces in XML (prefix binding, QName syntax).
    getter? namespace_aware : Bool
    # Maximum number of entity references expanded in one document.
    getter max_entity_expansions : Int32
    # Maximum total bytes produced by entity expansion in one document.
    getter max_entity_expansion_bytes : Int64
    # Maximum nesting of entity references inside entity replacement text.
    getter max_entity_depth : Int32
    # Maximum number of attributes added from DTD defaults in one document.
    getter max_default_attributes : Int32
    # Maximum total bytes of attribute values added from DTD defaults in one
    # document.
    getter max_default_attribute_bytes : Int64
    # Maximum element nesting depth.
    getter max_element_depth : Int32
    # Maximum length in bytes of a single name (element, attribute, entity,
    # PI target, name token).
    getter max_name_bytes : Int32
    # Maximum number of attributes on one element.
    getter max_attributes : Int32
    # Maximum size in bytes of one token: a text node, attribute value,
    # comment, PI, CDATA section or the internal DTD subset.
    getter max_token_bytes : Int32
    # Maximum size in bytes of the whole input (decoded), or nil for no cap.
    getter max_input_bytes : Int64?
    # The work budget and deadline every parse runs under. The deadline is
    # checked at work-budget checkpoints, after every IO read that returns,
    # and at the start and end of the parse; it bounds the parser's own
    # work. A read from a blocking IO that never returns cannot be
    # interrupted, so for a guaranteed wall-clock bound over an untrusted
    # stream give the IO its own read timeout (for example
    # `Socket#read_timeout`).
    getter work_budget : Core::WorkBudget
    # Verifies XML 1.1 full normalization (section 2.13): every text,
    # attribute value, comment, PI, CDATA section and name is in Unicode
    # NFC, and none of them starts with a composing character. Raises
    # `Mica::XML::NormalizationError`. Applies to XML 1.1 documents.
    getter? check_normalization : Bool

    def initialize(
      @namespace_aware : Bool = true,
      @max_entity_expansions : Int32 = 10_000,
      @max_entity_expansion_bytes : Int64 = 16_i64 * 1024 * 1024,
      @max_entity_depth : Int32 = 16,
      @max_default_attributes : Int32 = 1_000_000,
      @max_default_attribute_bytes : Int64 = 16_i64 * 1024 * 1024,
      @max_element_depth : Int32 = 1024,
      @max_name_bytes : Int32 = 50_000,
      @max_attributes : Int32 = 10_000,
      @max_token_bytes : Int32 = 10 * 1024 * 1024,
      @max_input_bytes : Int64? = nil,
      @work_budget : Core::WorkBudget = DEFAULT_WORK_BUDGET,
      @check_normalization : Bool = false,
    )
    end

    # Returns the default options.
    def self.default : self
      new
    end
  end
end
