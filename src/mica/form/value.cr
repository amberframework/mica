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
  #
  # Under `invalid_utf8: :replace_like_browsers`, `has_replaced_invalid_bytes?`
  # says whether invalid UTF-8 was replaced with U+FFFD in any pair that
  # reached this node; ask the root to learn whether the parse altered
  # anything.
  struct Value
    # The node's content.
    getter raw : (String | Hash(String, Value) | Array(Value))?

    def initialize(@raw : (String | Hash(String, Value) | Array(Value))?, *, @has_replaced_invalid_bytes : Bool = false)
    end

    # Returns true when a pair whose invalid UTF-8 was replaced with U+FFFD
    # (under `invalid_utf8: :replace_like_browsers`) reached this node: its
    # string, or any string or key below it. On the root it answers
    # whether the parse replaced anything at all. `==` compares content
    # only and ignores this flag.
    #
    # ```
    # value = Mica::Form.parse("q=caf%E9&page=2", limits: Mica::Form::Limits::QUERY_STRING, invalid_utf8: :replace_like_browsers)
    # value.has_replaced_invalid_bytes?         # => true
    # value["q"].has_replaced_invalid_bytes?    # => true
    # value["page"].has_replaced_invalid_bytes? # => false
    # ```
    def has_replaced_invalid_bytes? : Bool
      @has_replaced_invalid_bytes
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

    # Hashes the content only, to agree with `==`.
    def hash(hasher)
      @raw.hash(hasher)
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
