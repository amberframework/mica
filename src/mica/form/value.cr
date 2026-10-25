module Mica::Form
  # A node of the nested structure `NestedKeys` builds: a string, a hash
  # (keys in first-seen order), an array, or nil (an array slot no key
  # named, between sparse indices).
  #
  # ```
  # value = Mica::Form.parse("user[name]=Ada&user[tags][]=x", limits: Mica::Form::Limits::REQUEST_BODY)
  # value["user"]["name"].as_s    # => "Ada"
  # value["user"]["tags"][0].as_s # => "x"
  # value["user"]["missing"]?     # => nil
  # ```
  #
  # The `as_` accessors raise `TypeCastError` for the wrong kind, and the
  # `as_..?` forms return nil; `[]` raises `KeyError` or `IndexError` for
  # a missing entry, and `[]?` returns nil.
  struct Value
    # The node's content.
    getter raw : (String | Hash(String, Value) | Array(Value))?

    def initialize(@raw : (String | Hash(String, Value) | Array(Value))?)
    end

    # Returns the string, or nil for another kind.
    def as_s? : String?
      raw = @raw
      raw.is_a?(String) ? raw : nil
    end

    # Returns the string. Raises `TypeCastError` for another kind.
    def as_s : String
      as_s? || raise_kind("String")
    end

    # Returns the hash, or nil for another kind.
    def as_h? : Hash(String, Value)?
      raw = @raw
      raw.is_a?(Hash) ? raw : nil
    end

    # Returns the hash. Raises `TypeCastError` for another kind.
    def as_h : Hash(String, Value)
      as_h? || raise_kind("Hash")
    end

    # Returns the array, or nil for another kind.
    def as_a? : Array(Value)?
      raw = @raw
      raw.is_a?(Array) ? raw : nil
    end

    # Returns the array. Raises `TypeCastError` for another kind.
    def as_a : Array(Value)
      as_a? || raise_kind("Array")
    end

    # Returns true for an empty array slot.
    def empty_slot? : Bool
      @raw.nil?
    end

    # Returns the entry *key* of a hash, or nil when it is missing or this
    # is not a hash.
    def []?(key : String) : Value?
      hash = as_h?
      hash ? hash[key]? : nil
    end

    # Returns the entry *key* of a hash. Raises `KeyError` when it is
    # missing and `TypeCastError` when this is not a hash.
    def [](key : String) : Value
      as_h[key]? || raise KeyError.new("Missing form key #{Core.quote(key)}")
    end

    # Returns the element at *index* of an array, or nil when it is out of
    # range or this is not an array.
    def []?(index : Int) : Value?
      array = as_a?
      array ? array[index]? : nil
    end

    # Returns the element at *index* of an array. Raises `IndexError` when
    # it is out of range and `TypeCastError` when this is not an array.
    def [](index : Int) : Value
      as_a[index]
    end

    # Returns the number of entries of a hash or array, or the characters
    # of a string; 0 for an empty slot.
    def size : Int32
      raw = @raw
      raw.nil? ? 0 : raw.size
    end

    def ==(other : Value) : Bool
      @raw == other.raw
    end

    def to_s(io : IO) : Nil
      @raw.inspect(io)
    end

    def inspect(io : IO) : Nil
      @raw.inspect(io)
    end

    private def raise_kind(expected : String) : NoReturn
      raise TypeCastError.new("Expected a form #{expected}, not #{@raw.class}")
    end
  end
end
