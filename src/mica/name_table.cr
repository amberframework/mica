module Mica
  # :nodoc:
  #
  # Interns names and namespace URIs. Lookup hashes the raw bytes and
  # compares in place, so a name that was seen before costs no allocation.
  # Ids are dense Int32 values starting at 0; id 0 is always the empty
  # string.
  #
  # The hash is seeded per table so that an attacker who controls the
  # document cannot precompute colliding names.
  class NameTable
    @strings : Array(String)
    @hashes : Array(UInt32)
    @local_ids : Array(Int32)
    @prefix_ids : Array(Int32)
    @qname_states : Array(Int8)
    @slots : Slice(Int32)
    @mask : Int32
    @seed : UInt32

    EMPTY_ID = 0

    def initialize
      @strings = [] of String
      @hashes = [] of UInt32
      @local_ids = [] of Int32
      @prefix_ids = [] of Int32
      @qname_states = [] of Int8
      @slots = Slice(Int32).new(256, -1)
      @mask = 255
      @seed = Random::Secure.rand(UInt32)
      intern("".to_slice)
    end

    def size : Int32
      @strings.size
    end

    # Returns the string for *id*.
    @[AlwaysInline]
    def [](id : Int32) : String
      @strings.unsafe_fetch(id)
    end

    # Returns the id of *bytes*, adding it if needed.
    def intern(bytes : Bytes) : Int32
      hash = hash_bytes(bytes)
      index = hash.to_i32! & @mask
      loop do
        id = @slots.unsafe_fetch(index)
        if id < 0
          return add(bytes, hash, index)
        end
        if @hashes.unsafe_fetch(id) == hash && @strings.unsafe_fetch(id).to_slice == bytes
          return id
        end
        index = (index + 1) & @mask
      end
    end

    # Returns the id of *string*, adding it if needed.
    def intern(string : String) : Int32
      intern(string.to_slice)
    end

    # Returns the id of *bytes* or -1 if it was never interned.
    def lookup(bytes : Bytes) : Int32
      hash = hash_bytes(bytes)
      index = hash.to_i32! & @mask
      loop do
        id = @slots.unsafe_fetch(index)
        return -1 if id < 0
        if @hashes.unsafe_fetch(id) == hash && @strings.unsafe_fetch(id).to_slice == bytes
          return id
        end
        index = (index + 1) & @mask
      end
    end

    # Returns the id of the part after the first colon of name *id* (the
    # whole name when there is no colon).
    def local_id(id : Int32) : Int32
      cached = @local_ids.unsafe_fetch(id)
      return cached if cached >= 0
      split(id)
      @local_ids.unsafe_fetch(id)
    end

    # Returns the id of the part before the first colon of name *id*
    # (`EMPTY_ID` when there is no colon).
    def prefix_id(id : Int32) : Int32
      cached = @prefix_ids.unsafe_fetch(id)
      return cached if cached >= 0
      split(id)
      @prefix_ids.unsafe_fetch(id)
    end

    # Returns true when name *id* is a valid QName (Namespaces in XML 1.0):
    # at most one colon, neither first nor last, and the local part starts
    # with a NameStartChar.
    def qname?(id : Int32) : Bool
      state = @qname_states.unsafe_fetch(id)
      if state == 0
        state = check_qname(@strings.unsafe_fetch(id).to_slice) ? 1_i8 : 2_i8
        @qname_states[id] = state
      end
      state == 1
    end

    # Returns true when name *id* contains no colon (an NCName).
    def ncname?(id : Int32) : Bool
      !@strings.unsafe_fetch(id).to_slice.includes?(':'.ord.to_u8)
    end

    private def check_qname(bytes : Bytes) : Bool
      colon = bytes.index(':'.ord.to_u8)
      return true unless colon
      return false if colon == 0 || colon == bytes.size - 1
      return false if bytes.index(':'.ord.to_u8, colon + 1)
      code, length = CharClass.decode_utf8(bytes.to_unsafe + colon + 1, bytes.size - colon - 1)
      length > 0 && CharClass.name_start_char?(code)
    end

    private def split(id : Int32) : Nil
      bytes = @strings.unsafe_fetch(id).to_slice
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
      @hashes << hash
      @local_ids << -1
      @prefix_ids << -1
      @qname_states << 0_i8
      @slots[index] = id
      grow if @strings.size * 2 > @slots.size
      id
    end

    private def grow : Nil
      new_size = @slots.size * 2
      @slots = Slice(Int32).new(new_size, -1)
      @mask = new_size - 1
      @hashes.each_with_index do |hash, id|
        index = hash.to_i32! & @mask
        while @slots.unsafe_fetch(index) >= 0
          index = (index + 1) & @mask
        end
        @slots[index] = id
      end
    end

    # Seeded FNV-1a over the bytes followed by a final avalanche step.
    @[AlwaysInline]
    private def hash_bytes(bytes : Bytes) : UInt32
      hash = 2166136261_u32 ^ @seed
      ptr = bytes.to_unsafe
      bytes.size.times do |i|
        hash = (hash ^ ptr[i]) &* 16777619_u32
      end
      hash ^= hash >> 16
      hash &*= 0x7feb352d_u32
      hash ^= hash >> 15
      hash &*= 0x846ca68b_u32
      hash ^ (hash >> 16)
    end
  end
end
