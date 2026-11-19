module Mica::Regex
  # Groups the 256 byte values into classes that no part of a program can
  # tell apart: every byte range of every state starts and ends on a class
  # boundary, and so do the bytes the assertions look at (the line feed,
  # the ASCII word characters, UTF-8 continuation bytes and non-ASCII
  # bytes). The lazy DFA and the one-pass DFA keep one transition per class
  # instead of one per byte, and use a class's first byte (its
  # representative) wherever a byte is needed.
  class ByteClasses
    # The number of classes (1 to 256).
    getter class_count : Int32
    @class_of : StaticArray(UInt8, 256)
    @list_of_representatives : Array(UInt8)

    def initialize(program : Program)
      boundaries = StaticArray(Bool, 257).new(false)
      mark = ->(low : Int32, high : Int32) do
        boundaries[low] = true
        boundaries[high + 1] = true
      end
      program.each_state do |state, _|
        mark.call(state.low.to_i32, state.high.to_i32) if state.kind.byte_range?
      end
      program.each_transition_range { |low, high| mark.call(low.to_i32, high.to_i32) }
      mark.call(0x0A, 0x0A)
      mark.call(0x30, 0x39)
      mark.call(0x41, 0x5A)
      mark.call(0x5F, 0x5F)
      mark.call(0x61, 0x7A)
      mark.call(0x80, 0xBF)
      @class_of = StaticArray(UInt8, 256).new(0_u8)
      @list_of_representatives = [0_u8]
      current = 0
      (1..255).each do |byte|
        if boundaries[byte]
          current += 1
          @list_of_representatives << byte.to_u8
        end
        @class_of[byte] = current.to_u8
      end
      @class_count = current + 1
    end

    # Returns the class of *byte*.
    @[AlwaysInline]
    def class_of(byte : UInt8) : Int32
      @class_of.unsafe_fetch(byte).to_i32
    end

    # Returns the first byte of class *class_index*.
    def representative(class_index : Int32) : UInt8
      @list_of_representatives[class_index]
    end

    # :nodoc:
    # The byte-to-class table, for the search loops.
    def table : Pointer(UInt8)
      @class_of.to_unsafe
    end
  end
end
