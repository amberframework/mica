module Mica::YAML
  # A node of a composed document: a `Scalar`, a `Sequence` or a
  # `Mapping`. An alias is not a node of its own: it is the node its anchor
  # names, so a document with aliases is a graph and the same node object
  # can sit in several places.
  abstract class Node
    # The node's tag with its handle resolved (`!!str` reads as
    # `tag:yaml.org,2002:str`), or nil when it has none.
    getter tag : String?

    # The node's anchor, or nil.
    getter anchor : String?

    # Where the node starts in the input.
    getter position : Core::Position

    # The nodes this node stands for once every alias under it is
    # replaced by a copy of its target (1 for a scalar).
    #
    # :nodoc:
    property expanded_size : Int64 = 1_i64

    def initialize(@tag : String?, @anchor : String?, @position : Core::Position)
    end
  end

  # A scalar node: its text (escapes and line folding already applied) and
  # the style it was written in.
  class Scalar < Node
    getter value : String
    getter style : ScalarStyle

    def initialize(@value : String, @style : ScalarStyle, tag : String?, anchor : String?, position : Core::Position)
      super(tag, anchor, position)
    end
  end

  # A sequence node and its items in order.
  class Sequence < Node
    getter list_of_items : Array(Node) = [] of Node
    getter style : SequenceStyle

    def initialize(@style : SequenceStyle, tag : String?, anchor : String?, position : Core::Position)
      super(tag, anchor, position)
    end
  end

  # A mapping node and its key and value pairs in order (duplicate keys
  # included, as written).
  class Mapping < Node
    getter list_of_pairs : Array({Node, Node}) = [] of {Node, Node}
    getter style : MappingStyle

    def initialize(@style : MappingStyle, tag : String?, anchor : String?, position : Core::Position)
      super(tag, anchor, position)
    end
  end
end
