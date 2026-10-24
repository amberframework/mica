module Mica::XML
  # A namespace binding: a prefix (nil for the default namespace) and its
  # URI.
  struct Namespace
    getter document : Document
    getter prefix : String?
    getter href : String?

    def initialize(@document : Document, @prefix : String?, @href : String?)
    end

    def ==(other : Namespace) : Bool
      @prefix == other.prefix && @href == other.href
    end

    def hash(hasher)
      hasher = @prefix.hash(hasher)
      @href.hash(hasher)
    end

    def to_s(io : IO) : Nil
      io << "#<Mica::XML::Namespace"
      if prefix = @prefix
        io << " prefix="
        prefix.inspect(io)
      end
      if href = @href
        io << " href="
        href.inspect(io)
      end
      io << '>'
    end

    def inspect(io : IO) : Nil
      to_s(io)
    end
  end
end
