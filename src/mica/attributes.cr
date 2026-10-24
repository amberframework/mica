module Mica
  # The attributes of an element (namespace declarations are not
  # included; see `Node#namespace_definitions`).
  struct Attributes
    include Enumerable(Node)

    def initialize(@node : Node)
    end

    def each(&) : Nil
      @node.each_attribute_index do |index|
        yield Node.new(@node.document, index)
      end
    end

    def empty? : Bool
      each { return false }
      true
    end

    # Returns the attribute at *index* (negative counts from the end).
    def [](index : Int) : Node
      list = to_a
      list[index]
    end

    # Returns the attribute named *name*. Raises `KeyError` when missing.
    def [](name : String) : Node
      self[name]? || raise KeyError.new("Missing attribute: #{name}")
    end

    # Returns the attribute whose qualified or local name is *name*, or nil.
    def []?(name : String) : Node?
      find { |attribute| attribute.qualified_name == name } || find { |attribute| attribute.name == name }
    end

    # Sets attribute *name* on the element.
    def []=(name : String, value) : String
      @node[name] = value
    end

    # Removes attribute *name* and returns its value.
    def delete(name : String) : String?
      @node.delete(name)
    end

    def to_s(io : IO) : Nil
      io << '['
      join(io, ", ") { |attribute, inner| attribute.inspect(inner) }
      io << ']'
    end

    def inspect(io : IO) : Nil
      to_s(io)
    end
  end
end
