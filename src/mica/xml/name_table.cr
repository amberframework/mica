module Mica::XML
  # :nodoc:
  #
  # Interns names and namespace URIs. Lookup hashes the raw bytes and
  # compares in place, so a name that was seen before costs no allocation.
  # Ids are dense Int32 values starting at 0; id 0 is always the empty
  # string.
  #
  # The hash is seeded per table so that an attacker who controls the
  # document cannot precompute colliding names. As a second line of defense
  # a probe sequence longer than MAX_PROBES, or a run of occupied slots
  # longer than MAX_RUN, makes the table pick a new seed and rehash, so a
  # lookup of any name, present or absent, never costs more than its name's
  # length plus MAX_RUN + 1 probes, and a run of collisions cannot persist.
  #
  # `operations` counts all the work for the reader's work meter: each
  # lookup's name bytes (hashing), every slot probed, the bytes compared,
  # and every name rehashed when the table grows or reseeds. Probe counts
  # depend on the seed; tests that need reproducible operation counts pass
  # a fixed *seed*.
  class NameTable
    # Longest probe sequence tolerated before reseeding. With a random seed
    # and a load factor of at most 1/2, sequences this long are vanishingly
    # rare, so reseeding only happens under attack (or astronomically bad
    # luck, which it also cures).
    MAX_PROBES = 128

    # Longest run of occupied slots the table keeps. A lookup of any name,
    # present or absent, stops at the end of its run, so it probes at most
    # MAX_RUN + 1 slots; a run that grows longer makes the table reseed.
    MAX_RUN = 2 * MAX_PROBES

    # Reseeds allowed per table before giving up with an error.
    MAX_RESEEDS = 16

    # Returns the number of slots examined by all lookups so far.
    getter probes : Int64 = 0_i64

    # Returns the work of all lookups, growth and reseeding so far.
    getter operations : Int64 = 0_i64

    # The part of `operations` already reported through `before_rebuild`.
    # An owner charging `operations` to its meter charges only the rest
    # (see `unpaid_operations`).
    getter prepaid_operations : Int64 = 0_i64

    # Bytes of all interned names plus one per name, kept as names are
    # added so a reseed knows its rehash work without walking the names.
    @name_bytes = 0_i64

    @reseeds = 0
    @fixed_seed = false

    # Called with the work a rehash is about to do (slots allocated plus
    # names placed, and the name bytes rehashed when reseeding) before it
    # starts, so the owner's work meter can stop it first. The reader that
    # fills the table sets it.
    property before_rebuild : Proc(Int64, Nil)? = nil

    @strings : Array(String)
    @hashes : Array(UInt32)
    @local_ids : Array(Int32)
    @prefix_ids : Array(Int32)
    @qname_states : Array(Int8)
    @slots : Slice(Int32)
    @mask : Int32
    @seed : UInt32

    EMPTY_ID = 0

    # *seed* fixes the hash seed (for reproducible tests); by default each
    # table draws a random one, and reseeding always draws a fresh one
    # unless a seed was given.
    def initialize(seed : UInt32? = nil)
      @fixed_seed = !seed.nil?
      @strings = [] of String
      @hashes = [] of UInt32
      @local_ids = [] of Int32
      @prefix_ids = [] of Int32
      @qname_states = [] of Int8
      @slots = Slice(Int32).new(256, -1)
      @mask = 255
      @seed = seed || Random::Secure.rand(UInt32)
      intern("".to_slice)
    end

    def size : Int32
      @strings.size
    end

    # Returns the string for *id*.
    @[AlwaysInline]
    def [](id : Int32) : String
      @strings[id]
    end

    # Returns the id of *bytes*, adding it if needed.
    def intern(bytes : Bytes) : Int32
      @operations += bytes.size + 1
      hash = hash_bytes(bytes)
      index = hash.to_i32! & @mask
      steps = 0
      loop do
        @probes += 1
        id = @slots[index]
        if id < 0
          @operations += steps
          id = add(bytes, hash, index)
          reseed if steps > MAX_PROBES
          return id
        end
        if @hashes[id] == hash
          @operations += bytes.size
          if same_bytes?(@strings[id], bytes)
            @operations += steps
            reseed if steps > MAX_PROBES
            return id
          end
        end
        index = (index + 1) & @mask
        steps += 1
      end
    end

    # Names are short: an in-place byte comparison beats memcmp here.
    @[AlwaysInline]
    private def same_bytes?(string : String, bytes : Bytes) : Bool
      string.bytesize == bytes.size && Core::ByteScan.matches?(bytes, 0, string.to_slice)
    end

    # Returns the id of *string*, adding it if needed.
    def intern(string : String) : Int32
      intern(string.to_slice)
    end

    # Returns the id of *bytes* or -1 if it was never interned.
    def lookup(bytes : Bytes) : Int32
      @operations += bytes.size + 1
      hash = hash_bytes(bytes)
      index = hash.to_i32! & @mask
      loop do
        @probes += 1
        @operations += 1
        id = @slots[index]
        return -1 if id < 0
        if @hashes[id] == hash
          @operations += bytes.size
          return id if same_bytes?(@strings[id], bytes)
        end
        index = (index + 1) & @mask
      end
    end

    # Returns the id of the part after the first colon of name *id* (the
    # whole name when there is no colon).
    def local_id(id : Int32) : Int32
      cached = @local_ids[id]
      return cached if cached >= 0
      split(id)
      @local_ids[id]
    end

    # Returns the id of the part before the first colon of name *id*
    # (`EMPTY_ID` when there is no colon).
    def prefix_id(id : Int32) : Int32
      cached = @prefix_ids[id]
      return cached if cached >= 0
      split(id)
      @prefix_ids[id]
    end

    # Returns true when name *id* is a valid QName (Namespaces in XML 1.0):
    # at most one colon, neither first nor last, and the local part starts
    # with a NameStartChar.
    def qname?(id : Int32) : Bool
      state = @qname_states[id]
      if state == 0
        state = check_qname(@strings[id].to_slice) ? 1_i8 : 2_i8
        @qname_states[id] = state
      end
      state == 1
    end

    # Returns true when name *id* contains no colon (an NCName).
    def ncname?(id : Int32) : Bool
      !@strings[id].to_slice.includes?(':'.ord.to_u8)
    end

    private def check_qname(bytes : Bytes) : Bool
      colon = bytes.index(':'.ord.to_u8)
      return true unless colon
      return false if colon == 0 || colon == bytes.size - 1
      return false if bytes.index(':'.ord.to_u8, colon + 1)
      code, length = Core::UTF8.decode(bytes[colon + 1, bytes.size - colon - 1])
      length > 0 && CharClass.name_start_char?(code)
    end

    private def split(id : Int32) : Nil
      bytes = @strings[id].to_slice
      colon = bytes.index(':'.ord.to_u8)
      if colon
        prefix = intern(bytes[0, colon])
        local = intern(bytes[colon + 1, bytes.size - colon - 1])
      else
        prefix = EMPTY_ID
        local = id
      end
      @prefix_ids[id] = prefix
      @local_ids[id] = local
    end

    private def add(bytes : Bytes, hash : UInt32, index : Int32) : Int32
      id = @strings.size
      @strings << String.new(bytes)
      @name_bytes += bytes.size + 1
      @hashes << hash
      @local_ids << -1
      @prefix_ids << -1
      @qname_states << 0_i8
      @slots[index] = id
      reseed if run_too_long?(index)
      grow if @strings.size * 2 > @slots.size
      id
    end

    # True when the run of occupied slots around *index* is longer than
    # MAX_RUN. Examines at most MAX_RUN + 2 slots.
    private def run_too_long?(index : Int32) : Bool
      length = 1
      left = (index - 1) & @mask
      while @slots[left] >= 0
        length += 1
        break if length > MAX_RUN
        left = (left - 1) & @mask
      end
      right = (index + 1) & @mask
      while length <= MAX_RUN && @slots[right] >= 0
        length += 1
        right = (right + 1) & @mask
      end
      @operations += length
      length > MAX_RUN
    end

    private def grow : Nil
      reseed unless rebuild(@slots.size * 2)
    end

    # Picks a new seed and rehashes every name, until every run is at most
    # MAX_RUN long (after a probe sequence longer than MAX_PROBES or a run
    # longer than MAX_RUN).
    private def reseed : Nil
      loop do
        @reseeds += 1
        raise Mica::Error.new("Name table hash collisions persist after #{MAX_RESEEDS} reseeds") if @reseeds > MAX_RESEEDS
        account_rebuild(@name_bytes)
        @seed = @fixed_seed ? mix_seed(@seed &+ @reseeds) : Random::Secure.rand(UInt32)
        @probes += @name_bytes - @strings.size
        @strings.each_with_index do |string, id|
          @hashes[id] = hash_bytes(string.to_slice)
        end
        break if rebuild(@slots.size)
      end
    end

    # Places every name in a table of *new_size* slots. Returns false, after
    # bounded work, when a placement probes past MAX_RUN or a run is longer
    # than MAX_RUN (the caller then reseeds).
    private def rebuild(new_size : Int32) : Bool
      # Slots allocated, names placed and the run check; collision probes
      # are counted as they happen.
      account_rebuild(2 * new_size.to_i64 + @hashes.size)
      @slots = Slice(Int32).new(new_size, -1)
      @mask = new_size - 1
      @hashes.each_with_index do |hash, id|
        index = hash.to_i32! & @mask
        steps = 0
        while @slots[index] >= 0
          @probes += 1
          @operations += 1
          steps += 1
          return false if steps > MAX_RUN
          index = (index + 1) & @mask
        end
        @slots[index] = id
      end
      runs_bounded?
    end

    # True when no run of occupied slots is longer than MAX_RUN.
    private def runs_bounded? : Bool
      # A run may wrap around the end: start counting after an empty slot.
      first_empty = @slots.index(-1) || return false
      length = 0
      @slots.size.times do |offset|
        if @slots[(first_empty + offset) & @mask] >= 0
          length += 1
          return false if length > MAX_RUN
        else
          length = 0
        end
      end
      true
    end

    # Returns the work in `operations` not yet reported through
    # `before_rebuild`; it never decreases.
    def unpaid_operations : Int64
      @operations - @prepaid_operations
    end

    # Counts *work* a rehash is about to do and reports it through
    # `before_rebuild` (when set) before the rehash starts.
    private def account_rebuild(work : Int64) : Nil
      @operations += work
      if hook = @before_rebuild
        @prepaid_operations += work
        hook.call(work)
      end
    end

    # Derives the next seed of a table with a fixed seed.
    private def mix_seed(value : UInt32) : UInt32
      value ^= value >> 16
      value &*= 0x7feb352d_u32
      value ^= value >> 15
      value &*= 0x846ca68b_u32
      value ^ (value >> 16)
    end

    # Seeded FNV-1a over the bytes followed by a final avalanche step.
    @[AlwaysInline]
    private def hash_bytes(bytes : Bytes) : UInt32
      hash = 2166136261_u32 ^ @seed
      bytes.each do |byte|
        hash = (hash ^ byte) &* 16777619_u32
      end
      hash ^= hash >> 16
      hash &*= 0x7feb352d_u32
      hash ^= hash >> 15
      hash &*= 0x846ca68b_u32
      hash ^ (hash >> 16)
    end
  end
end
