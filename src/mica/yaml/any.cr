module Mica::YAML
  # A parsed YAML value: nil, a boolean, an integer, a float, a string, an
  # array of values or a hash from values to values. `Mica::YAML.parse`
  # returns one.
  #
  # ```
  # limits = Mica::YAML::ParseLimits::CONFIG_FILE
  # config = Mica::YAML.parse("server:\n  port: 3000\n  hosts: [a, b]\n", limits: limits, timeout: nil)
  # config["server"]["port"].as_i     # => 3000
  # config["server"]["hosts"][1].as_s # => "b"
  # config["server"]["tls"]?          # => nil
  # ```
  #
  # A value an alias points to is shared, not copied: the same array or
  # hash object appears wherever the alias does.
  struct Any
    # The types a value can hold.
    alias Type = Nil | Bool | Int64 | Float64 | String | Array(Any) | Hash(Any, Any)

    # Returns the value itself.
    getter raw : Type

    def initialize(@raw : Type)
    end

    # Returns the number of items of an array or entries of a hash. Raises
    # `Mica::Error` for other values.
    def size : Int32
      raw = @raw
      if raw.is_a?(Array)
        raw.size
      elsif raw.is_a?(Hash)
        raw.size
      else
        raise Mica::Error.new("Expected an array or a hash, not #{type_name}")
      end
    end

    # Returns the item at *index* of an array. Raises `IndexError` when it
    # is out of range and `Mica::Error` when the value is not an array.
    def [](index : Int) : Any
      as_a[index]
    end

    # Returns the item at *index* of an array, or nil when it is out of
    # range. Raises `Mica::Error` when the value is not an array.
    def []?(index : Int) : Any?
      as_a[index]?
    end

    # Returns the value under *key* of a hash. Raises `KeyError` when the
    # key is missing and `Mica::Error` when the value is not a hash.
    def [](key : String | Any) : Any
      as_h[key.is_a?(Any) ? key : Any.new(key)]
    end

    # Returns the value under *key* of a hash, or nil when the key is
    # missing. Raises `Mica::Error` when the value is not a hash.
    def []?(key : String | Any) : Any?
      as_h[key.is_a?(Any) ? key : Any.new(key)]?
    end

    # Returns true when the value is nil.
    def as_nil : Nil
      expect("nil") unless @raw.nil?
    end

    {% for pair in [{"as_s", "String", "a string"}, {"as_bool", "Bool", "a boolean"}, {"as_i64", "Int64", "an integer"},
                    {"as_a", "Array(Any)", "an array"}, {"as_h", "Hash(Any, Any)", "a hash"}] %}
      # Returns the value as {{pair[2].id}}. Raises `Mica::Error` when it is
      # something else.
      def {{pair[0].id}} : {{pair[1].id}}
        raw = @raw
        raw.is_a?({{pair[1].id}}) ? raw : expect({{pair[2]}})
      end

      # Returns the value as {{pair[2].id}}, or nil when it is something else.
      def {{pair[0].id}}? : {{pair[1].id}}?
        raw = @raw
        raw.is_a?({{pair[1].id}}) ? raw : nil
      end
    {% end %}

    # Returns the value as an `Int32`. Raises `Mica::Error` when it is not
    # an integer and `OverflowError` when it does not fit.
    def as_i : Int32
      as_i64.to_i32
    end

    # Returns the value as an `Int32`, or nil when it is not an integer
    # that fits.
    def as_i? : Int32?
      as_i64?.try(&.to_i32?)
    end

    # Returns the value as a `Float64`; an integer converts. Raises
    # `Mica::Error` for other values.
    def as_f : Float64
      raw = @raw
      if raw.is_a?(Float64)
        raw
      elsif raw.is_a?(Int64)
        raw.to_f64
      else
        expect("a number")
      end
    end

    # Returns the value as a `Float64` (an integer converts), or nil.
    def as_f? : Float64?
      raw = @raw
      if raw.is_a?(Float64)
        raw
      elsif raw.is_a?(Int64)
        raw.to_f64
      end
    end

    def ==(other : Any) : Bool
      @raw == other.raw
    end

    def ==(other) : Bool
      @raw == other
    end

    def_hash @raw

    def to_s(io : IO) : Nil
      @raw.to_s(io)
    end

    def inspect(io : IO) : Nil
      @raw.inspect(io)
    end

    private def type_name : String
      raw = @raw
      if raw.nil?
        "nil"
      elsif raw.is_a?(Bool)
        "a boolean"
      elsif raw.is_a?(Int64)
        "an integer"
      elsif raw.is_a?(Float64)
        "a float"
      elsif raw.is_a?(String)
        "a string"
      elsif raw.is_a?(Array)
        "an array"
      else
        "a hash"
      end
    end

    private def expect(wanted : String) : NoReturn
      raise Mica::Error.new("Expected #{wanted}, not #{type_name}")
    end
  end
end
