module Mica::XML
  # :nodoc:
  #
  # Declarations read from the internal DTD subset. External subsets and
  # external entities are never fetched.
  class DTD
    # One `<!ENTITY>` declaration.
    class Entity
      getter name_id : Int32
      # Replacement text of an internal entity; nil for external entities.
      getter replacement : Bytes?
      getter system_id : String?
      getter public_id : String?
      # Notation name for unparsed (NDATA) entities.
      getter notation : String?
      getter? parameter : Bool
      # True when the replacement text contains `<`, `&` or `]` and so has to
      # be parsed rather than copied.
      getter? has_markup : Bool

      def initialize(@name_id : Int32, @replacement : Bytes?, @system_id : String?, @public_id : String?, @notation : String?, @parameter : Bool)
        has_markup = false
        if text = @replacement
          has_markup = text.any? { |byte| byte == '<'.ord || byte == '&'.ord || byte == ']'.ord }
        end
        @has_markup = has_markup
      end

      def external? : Bool
        @replacement.nil?
      end

      def unparsed? : Bool
        !@notation.nil?
      end
    end

    enum AttributeType
      CDATA
      ID
      IDREF
      IDREFS
      ENTITY
      ENTITIES
      NMTOKEN
      NMTOKENS
      NOTATION
      ENUMERATION

      def cdata? : Bool
        self == CDATA
      end
    end

    enum DefaultKind
      REQUIRED
      IMPLIED
      FIXED
      VALUE
    end

    # One attribute definition from an `<!ATTLIST>` declaration.
    record AttributeDecl,
      name_id : Int32,
      type : AttributeType,
      default_kind : DefaultKind,
      default_value : Bytes

    getter general_entities = {} of Int32 => Entity
    getter parameter_entities = {} of Int32 => Entity
    # Notation name => {public identifier, system identifier}.
    getter notations = {} of String => {String?, String?}
    property root_name : String = ""
    property public_id : String?
    property system_id : String?
    property internal_subset : String?
    # True when a reference to an external or undeclared parameter entity was
    # skipped, so later declarations may be missing (XML 1.0 section 5.1).
    property? skipped_parameter_entity : Bool = false

    # {element name id, attribute name id} => the first declaration.
    @attribute_declarations = {} of {Int32, Int32} => AttributeDecl
    # Element name id => declarations with a default value (#FIXED or a
    # plain default), in declaration order.
    @defaulted_attributes = {} of Int32 => Array(AttributeDecl)
    # Element name ids with at least one attribute declaration.
    @elements_with_attributes = Set(Int32).new

    # Records *decl* for *element_name_id* unless that attribute was already
    # declared (the first declaration binds, XML 1.0 section 3.3). Returns
    # true when it was recorded.
    def add_attribute_declaration(element_name_id : Int32, decl : AttributeDecl) : Bool
      key = {element_name_id, decl.name_id}
      return false if @attribute_declarations.has_key?(key)
      @attribute_declarations[key] = decl
      @elements_with_attributes << element_name_id
      if decl.default_kind.fixed? || decl.default_kind.value?
        (@defaulted_attributes[element_name_id] ||= [] of AttributeDecl) << decl
      end
      true
    end

    # Returns true when *element_name_id* has attribute declarations.
    def declares_attributes?(element_name_id : Int32) : Bool
      !@elements_with_attributes.empty? && @elements_with_attributes.includes?(element_name_id)
    end

    # Returns the declaration of attribute *attribute_name_id* on
    # *element_name_id*, or nil.
    def attribute_declaration(element_name_id : Int32, attribute_name_id : Int32) : AttributeDecl?
      @attribute_declarations[{element_name_id, attribute_name_id}]?
    end

    # Returns the declarations with defaults for *element_name_id*, or nil.
    def defaulted_attributes(element_name_id : Int32) : Array(AttributeDecl)?
      @defaulted_attributes[element_name_id]?
    end

    def external_subset? : Bool
      !@system_id.nil?
    end
  end
end
