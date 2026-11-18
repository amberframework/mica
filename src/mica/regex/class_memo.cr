module Mica::Regex
  # :nodoc:
  # A process-wide memo of what large classes cost to compile, so a class
  # such as `\w` or `\p{L}` (hundreds of ranges, hundreds of UTF-8 trie
  # states) is split into UTF-8 sequences once per process rather than once
  # per pattern. It plays the part PCRE2's static property tables play.
  #
  # Keyed by a set's bounds (`CodePointSet#list_of_bounds`), it holds the
  # preflight's state bound and the block of states and transitions the
  # compiler emitted for the set, with targets relative to the block and
  # the class's exit marked `EXIT`. Instantiating a block emits exactly the
  # states compiling the set would emit, in the same order, through the
  # compiler's own checks, so a program is the same with or without it.
  #
  # Only sets of at least `MIN_RANGES` ranges are kept, and at most
  # `MAX_ENTRIES` of each kind; after that, sets are compiled as usual.
  module ClassMemo
    MIN_RANGES  =  16
    MAX_ENTRIES = 256
    # The target that stands for the state after the class.
    EXIT = -2

    record Block, list_of_states : Array(Program::State), list_of_transitions : Array(Program::Transition),
      entry : Int32

    # A set's bounds as a hash key: the hash is computed in one pass over
    # the integers and equality is a `memcmp`, so a lookup costs far less
    # than hashing an `Array(Int32)` element by element.
    struct Key
      getter bounds : Slice(Int32)
      @digest : UInt64

      def initialize(@bounds : Slice(Int32))
        digest = 14695981039346656037_u64
        @bounds.each { |bound| digest = (digest ^ bound.to_u32!) &* 1099511628211_u64 }
        @digest = digest
      end

      def hash(hasher)
        @digest.hash(hasher)
      end

      def ==(other : Key) : Bool
        @digest == other.@digest && @bounds == other.bounds
      end

      # A copy that owns its bounds, for storing.
      def stored : Key
        Key.new(@bounds.dup)
      end
    end

    @@mutex = Mutex.new
    @@state_bounds = {} of Key => Int64
    @@blocks = {} of Key => Block

    private def self.key(set : CodePointSet) : Key
      bounds = set.list_of_bounds
      Key.new(Slice.new(bounds.to_unsafe, bounds.size, read_only: true))
    end

    def self.memoized?(set : CodePointSet) : Bool
      set.range_count >= MIN_RANGES
    end

    # Returns the preflight bound for *set*, computing it with the block
    # the first time.
    def self.state_bound(set : CodePointSet, & : -> Int64) : Int64
      lookup = key(set)
      if bound = @@mutex.synchronize { @@state_bounds[lookup]? }
        return bound
      end
      bound = yield
      @@mutex.synchronize { @@state_bounds[lookup.stored] = bound if @@state_bounds.size < MAX_ENTRIES }
      bound
    end

    # Returns the block emitted for *set*, or nil.
    def self.block(set : CodePointSet) : Block?
      lookup = key(set)
      @@mutex.synchronize { @@blocks[lookup]? }
    end

    # Records the block emitted for *set*.
    def self.store(set : CodePointSet, block : Block) : Nil
      stored = key(set).stored
      @@mutex.synchronize { @@blocks[stored] = block if @@blocks.size < MAX_ENTRIES }
    end
  end
end
