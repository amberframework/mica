module Mica::HPACK
  # The canonical Huffman code of RFC 7541 Appendix B: 256 octets plus EOS
  # (symbol 256), codes 5 to 30 bits long.
  #
  # Decoding runs a finite-state machine four bits at a time, built once
  # from the code: each state is an internal node of the code tree, and
  # each of its 16 transitions names the next node, the symbol completed on
  # the way (four bits complete at most one, since the shortest code has
  # five) and whether the walk reached EOS.
  module Huffman
    # The code of each symbol, right-aligned.
    CODES = StaticArray[
      0x1ff8_u32, 0x7fffd8_u32, 0xfffffe2_u32, 0xfffffe3_u32, 0xfffffe4_u32, 0xfffffe5_u32, 0xfffffe6_u32, 0xfffffe7_u32,
      0xfffffe8_u32, 0xffffea_u32, 0x3ffffffc_u32, 0xfffffe9_u32, 0xfffffea_u32, 0x3ffffffd_u32, 0xfffffeb_u32, 0xfffffec_u32,
      0xfffffed_u32, 0xfffffee_u32, 0xfffffef_u32, 0xffffff0_u32, 0xffffff1_u32, 0xffffff2_u32, 0x3ffffffe_u32, 0xffffff3_u32,
      0xffffff4_u32, 0xffffff5_u32, 0xffffff6_u32, 0xffffff7_u32, 0xffffff8_u32, 0xffffff9_u32, 0xffffffa_u32, 0xffffffb_u32,
      0x14_u32, 0x3f8_u32, 0x3f9_u32, 0xffa_u32, 0x1ff9_u32, 0x15_u32, 0xf8_u32, 0x7fa_u32,
      0x3fa_u32, 0x3fb_u32, 0xf9_u32, 0x7fb_u32, 0xfa_u32, 0x16_u32, 0x17_u32, 0x18_u32,
      0x0_u32, 0x1_u32, 0x2_u32, 0x19_u32, 0x1a_u32, 0x1b_u32, 0x1c_u32, 0x1d_u32,
      0x1e_u32, 0x1f_u32, 0x5c_u32, 0xfb_u32, 0x7ffc_u32, 0x20_u32, 0xffb_u32, 0x3fc_u32,
      0x1ffa_u32, 0x21_u32, 0x5d_u32, 0x5e_u32, 0x5f_u32, 0x60_u32, 0x61_u32, 0x62_u32,
      0x63_u32, 0x64_u32, 0x65_u32, 0x66_u32, 0x67_u32, 0x68_u32, 0x69_u32, 0x6a_u32,
      0x6b_u32, 0x6c_u32, 0x6d_u32, 0x6e_u32, 0x6f_u32, 0x70_u32, 0x71_u32, 0x72_u32,
      0xfc_u32, 0x73_u32, 0xfd_u32, 0x1ffb_u32, 0x7fff0_u32, 0x1ffc_u32, 0x3ffc_u32, 0x22_u32,
      0x7ffd_u32, 0x3_u32, 0x23_u32, 0x4_u32, 0x24_u32, 0x5_u32, 0x25_u32, 0x26_u32,
      0x27_u32, 0x6_u32, 0x74_u32, 0x75_u32, 0x28_u32, 0x29_u32, 0x2a_u32, 0x7_u32,
      0x2b_u32, 0x76_u32, 0x2c_u32, 0x8_u32, 0x9_u32, 0x2d_u32, 0x77_u32, 0x78_u32,
      0x79_u32, 0x7a_u32, 0x7b_u32, 0x7ffe_u32, 0x7fc_u32, 0x3ffd_u32, 0x1ffd_u32, 0xffffffc_u32,
      0xfffe6_u32, 0x3fffd2_u32, 0xfffe7_u32, 0xfffe8_u32, 0x3fffd3_u32, 0x3fffd4_u32, 0x3fffd5_u32, 0x7fffd9_u32,
      0x3fffd6_u32, 0x7fffda_u32, 0x7fffdb_u32, 0x7fffdc_u32, 0x7fffdd_u32, 0x7fffde_u32, 0xffffeb_u32, 0x7fffdf_u32,
      0xffffec_u32, 0xffffed_u32, 0x3fffd7_u32, 0x7fffe0_u32, 0xffffee_u32, 0x7fffe1_u32, 0x7fffe2_u32, 0x7fffe3_u32,
      0x7fffe4_u32, 0x1fffdc_u32, 0x3fffd8_u32, 0x7fffe5_u32, 0x3fffd9_u32, 0x7fffe6_u32, 0x7fffe7_u32, 0xffffef_u32,
      0x3fffda_u32, 0x1fffdd_u32, 0xfffe9_u32, 0x3fffdb_u32, 0x3fffdc_u32, 0x7fffe8_u32, 0x7fffe9_u32, 0x1fffde_u32,
      0x7fffea_u32, 0x3fffdd_u32, 0x3fffde_u32, 0xfffff0_u32, 0x1fffdf_u32, 0x3fffdf_u32, 0x7fffeb_u32, 0x7fffec_u32,
      0x1fffe0_u32, 0x1fffe1_u32, 0x3fffe0_u32, 0x1fffe2_u32, 0x7fffed_u32, 0x3fffe1_u32, 0x7fffee_u32, 0x7fffef_u32,
      0xfffea_u32, 0x3fffe2_u32, 0x3fffe3_u32, 0x3fffe4_u32, 0x7ffff0_u32, 0x3fffe5_u32, 0x3fffe6_u32, 0x7ffff1_u32,
      0x3ffffe0_u32, 0x3ffffe1_u32, 0xfffeb_u32, 0x7fff1_u32, 0x3fffe7_u32, 0x7ffff2_u32, 0x3fffe8_u32, 0x1ffffec_u32,
      0x3ffffe2_u32, 0x3ffffe3_u32, 0x3ffffe4_u32, 0x7ffffde_u32, 0x7ffffdf_u32, 0x3ffffe5_u32, 0xfffff1_u32, 0x1ffffed_u32,
      0x7fff2_u32, 0x1fffe3_u32, 0x3ffffe6_u32, 0x7ffffe0_u32, 0x7ffffe1_u32, 0x3ffffe7_u32, 0x7ffffe2_u32, 0xfffff2_u32,
      0x1fffe4_u32, 0x1fffe5_u32, 0x3ffffe8_u32, 0x3ffffe9_u32, 0xffffffd_u32, 0x7ffffe3_u32, 0x7ffffe4_u32, 0x7ffffe5_u32,
      0xfffec_u32, 0xfffff3_u32, 0xfffed_u32, 0x1fffe6_u32, 0x3fffe9_u32, 0x1fffe7_u32, 0x1fffe8_u32, 0x7ffff3_u32,
      0x3fffea_u32, 0x3fffeb_u32, 0x1ffffee_u32, 0x1ffffef_u32, 0xfffff4_u32, 0xfffff5_u32, 0x3ffffea_u32, 0x7ffff4_u32,
      0x3ffffeb_u32, 0x7ffffe6_u32, 0x3ffffec_u32, 0x3ffffed_u32, 0x7ffffe7_u32, 0x7ffffe8_u32, 0x7ffffe9_u32, 0x7ffffea_u32,
      0x7ffffeb_u32, 0xffffffe_u32, 0x7ffffec_u32, 0x7ffffed_u32, 0x7ffffee_u32, 0x7ffffef_u32, 0x7fffff0_u32, 0x3ffffee_u32,
      0x3fffffff_u32,
    ]

    # The length in bits of each symbol's code.
    LENGTHS = StaticArray[
      13_u8, 23_u8, 28_u8, 28_u8, 28_u8, 28_u8, 28_u8, 28_u8, 28_u8, 24_u8, 30_u8, 28_u8, 28_u8, 30_u8, 28_u8, 28_u8,
      28_u8, 28_u8, 28_u8, 28_u8, 28_u8, 28_u8, 30_u8, 28_u8, 28_u8, 28_u8, 28_u8, 28_u8, 28_u8, 28_u8, 28_u8, 28_u8,
      6_u8, 10_u8, 10_u8, 12_u8, 13_u8, 6_u8, 8_u8, 11_u8, 10_u8, 10_u8, 8_u8, 11_u8, 8_u8, 6_u8, 6_u8, 6_u8,
      5_u8, 5_u8, 5_u8, 6_u8, 6_u8, 6_u8, 6_u8, 6_u8, 6_u8, 6_u8, 7_u8, 8_u8, 15_u8, 6_u8, 12_u8, 10_u8,
      13_u8, 6_u8, 7_u8, 7_u8, 7_u8, 7_u8, 7_u8, 7_u8, 7_u8, 7_u8, 7_u8, 7_u8, 7_u8, 7_u8, 7_u8, 7_u8,
      7_u8, 7_u8, 7_u8, 7_u8, 7_u8, 7_u8, 7_u8, 7_u8, 8_u8, 7_u8, 8_u8, 13_u8, 19_u8, 13_u8, 14_u8, 6_u8,
      15_u8, 5_u8, 6_u8, 5_u8, 6_u8, 5_u8, 6_u8, 6_u8, 6_u8, 5_u8, 7_u8, 7_u8, 6_u8, 6_u8, 6_u8, 5_u8,
      6_u8, 7_u8, 6_u8, 5_u8, 5_u8, 6_u8, 7_u8, 7_u8, 7_u8, 7_u8, 7_u8, 15_u8, 11_u8, 14_u8, 13_u8, 28_u8,
      20_u8, 22_u8, 20_u8, 20_u8, 22_u8, 22_u8, 22_u8, 23_u8, 22_u8, 23_u8, 23_u8, 23_u8, 23_u8, 23_u8, 24_u8, 23_u8,
      24_u8, 24_u8, 22_u8, 23_u8, 24_u8, 23_u8, 23_u8, 23_u8, 23_u8, 21_u8, 22_u8, 23_u8, 22_u8, 23_u8, 23_u8, 24_u8,
      22_u8, 21_u8, 20_u8, 22_u8, 22_u8, 23_u8, 23_u8, 21_u8, 23_u8, 22_u8, 22_u8, 24_u8, 21_u8, 22_u8, 23_u8, 23_u8,
      21_u8, 21_u8, 22_u8, 21_u8, 23_u8, 22_u8, 23_u8, 23_u8, 20_u8, 22_u8, 22_u8, 22_u8, 23_u8, 22_u8, 22_u8, 23_u8,
      26_u8, 26_u8, 20_u8, 19_u8, 22_u8, 23_u8, 22_u8, 25_u8, 26_u8, 26_u8, 26_u8, 27_u8, 27_u8, 26_u8, 24_u8, 25_u8,
      19_u8, 21_u8, 26_u8, 27_u8, 27_u8, 26_u8, 27_u8, 24_u8, 21_u8, 21_u8, 26_u8, 26_u8, 28_u8, 27_u8, 27_u8, 27_u8,
      20_u8, 24_u8, 20_u8, 21_u8, 22_u8, 21_u8, 21_u8, 23_u8, 22_u8, 22_u8, 25_u8, 25_u8, 24_u8, 24_u8, 26_u8, 23_u8,
      26_u8, 27_u8, 26_u8, 26_u8, 27_u8, 27_u8, 27_u8, 27_u8, 27_u8, 28_u8, 27_u8, 27_u8, 27_u8, 27_u8, 27_u8, 26_u8,
      30_u8,
    ]

    # Symbol of the EOS code.
    EOS = 256

    # Transition bits: the next state in bits 0 to 7, the symbol emitted in
    # bits 8 to 15.
    private EMITS = 1_u32 << 16
    private FAILS = 1_u32 << 17

    # Builds the transition table and the accepting states.
    private def self.build_machine : {Slice(UInt32), Slice(Bool)}
      # Internal nodes; children >= 0 are nodes, < 0 are leaves (-1 - symbol).
      children = [{0, 0}]
      257.times do |symbol|
        node = 0
        length = LENGTHS[symbol].to_i
        code = CODES[symbol]
        (length - 1).downto(0) do |shift|
          bit = (code >> shift) & 1
          pair = children[node]
          child = bit == 0 ? pair[0] : pair[1]
          if shift == 0
            leaf = -1 - symbol
            children[node] = bit == 0 ? {leaf, pair[1]} : {pair[0], leaf}
          else
            if child == 0
              children << {0, 0}
              child = children.size - 1
              children[node] = bit == 0 ? {child, pair[1]} : {pair[0], child}
            end
            node = child
          end
        end
      end
      raise "Huffman tree has #{children.size} internal nodes" unless children.size == 256

      # A state accepts the end of a string when it is reached from the
      # root by at most seven 1 bits: that is valid padding.
      accepting = Slice(Bool).new(256, false)
      node = 0
      accepting[0] = true
      7.times do
        node = children[node][1]
        accepting[node] = true
      end

      table = Slice(UInt32).new(256 * 16, 0_u32)
      256.times do |state|
        16.times do |nibble|
          node = state
          entry = 0_u32
          3.downto(0) do |shift|
            pair = children[node]
            child = (nibble >> shift) & 1 == 0 ? pair[0] : pair[1]
            if child < 0
              symbol = -1 - child
              if symbol == EOS
                entry |= FAILS
                break
              end
              entry |= EMITS | (symbol.to_u32 << 8)
              node = 0
            else
              node = child
            end
          end
          table[state * 16 + nibble] = entry | node.to_u32
        end
      end
      {table, accepting}
    end

    private MACHINE = build_machine

    # The decoder's transitions, 16 per state.
    TRANSITIONS = MACHINE[0]
    # Whether a string may end in each state.
    ACCEPTING = MACHINE[1]

    # Returns the encoded length in bytes of *input*.
    def self.encoded_size(input : Bytes) : Int32
      bits = 0_i64
      input.each { |byte| bits += LENGTHS.to_unsafe[byte] }
      ((bits + 7) // 8).to_i32
    end

    # Writes *input* Huffman-coded to *output*, padded with 1 bits.
    def self.encode(input : Bytes, output : IO) : Nil
      accumulator = 0_u64
      count = 0
      codes = CODES.to_unsafe
      lengths = LENGTHS.to_unsafe
      input.each do |byte|
        accumulator = (accumulator << lengths[byte]) | codes[byte]
        count += lengths[byte]
        while count >= 8
          count -= 8
          output.write_byte((accumulator >> count).to_u8!)
        end
      end
      if count > 0
        output.write_byte(((accumulator << (8 - count)) | (0xff_u64 >> count)).to_u8!)
      end
    end

    # Decodes the Huffman string *input* into *output*, which must hold at
    # least `input.size * 8 // 5` bytes. Returns the bytes written, or -1
    # when the string contains EOS or ends with invalid padding.
    def self.decode(input : Bytes, output : UInt8*) : Int32
      table = TRANSITIONS.to_unsafe
      state = 0_u32
      written = 0
      input.each do |byte|
        entry = table[(state << 4) | (byte >> 4)]
        return -1 if entry & FAILS != 0
        if entry & EMITS != 0
          output[written] = (entry >> 8).to_u8!
          written += 1
        end
        state = entry & 0xff
        entry = table[(state << 4) | (byte & 0x0f)]
        return -1 if entry & FAILS != 0
        if entry & EMITS != 0
          output[written] = (entry >> 8).to_u8!
          written += 1
        end
        state = entry & 0xff
      end
      ACCEPTING[state] ? written : -1
    end
  end
end
