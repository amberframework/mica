module Mica
  # An ordered collection of nodes, as returned by `Node#children` and
  # XPath node-set results.
  struct NodeSet
    include Enumerable(Node)

    def initialize(@nodes : Array(Node) = [] of Node)
    end

    # Returns the node at *index*. Raises `IndexError` when out of range.
    def [](index : Int) : Node
      @nodes[index]
    end

    # Returns the node at *index*, or nil.
    def []?(index : Int) : Node?
      @nodes[index]?
    end

    def each(&) : Nil
      @nodes.each { |node| yield node }
    end

    def empty? : Bool
      @nodes.empty?
    end

    def size : Int32
      @nodes.size
    end

    # Returns the nodes as an array.
    def to_a : Array(Node)
      @nodes.dup
    end

    def to_s(io : IO) : Nil
      @nodes.each { |node| node.to_xml(io) }
    end

    def inspect(io : IO) : Nil
      io << '['
      @nodes.join(io, ", ") { |node, inner| node.inspect(inner) }
      io << ']'
    end
  end
end
