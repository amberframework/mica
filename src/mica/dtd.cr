module Mica
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
    getter attribute_decls = {} of Int32 => Array(AttributeDecl)
    # {element name id, attribute name id} pairs already declared.
    getter declared_attribute_keys = Set({Int32, Int32}).new
    # Notation name => {public identifier, system identifier}.
    getter notations = {} of String => {String?, String?}
    property root_name : String = ""
    property public_id : String?
    property system_id : String?
    property internal_subset : String?
    # True when a reference to an external or undeclared parameter entity was
    # skipped, so later declarations may be missing (XML 1.0 section 5.1).
    property? skipped_parameter_entity : Bool = false

    def declared_attributes(element_name_id : Int32) : Array(AttributeDecl)?
      @attribute_decls[element_name_id]?
    end

    def external_subset? : Bool
      !@system_id.nil?
    end
  end
end
