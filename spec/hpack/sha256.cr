# SHA-256 (FIPS 180-4) for checking pinned downloads in specs, so the specs
# need no OpenSSL.
module SpecSHA256
  K = StaticArray[
    0x428a2f98_u32, 0x71374491_u32, 0xb5c0fbcf_u32, 0xe9b5dba5_u32, 0x3956c25b_u32, 0x59f111f1_u32, 0x923f82a4_u32, 0xab1c5ed5_u32,
    0xd807aa98_u32, 0x12835b01_u32, 0x243185be_u32, 0x550c7dc3_u32, 0x72be5d74_u32, 0x80deb1fe_u32, 0x9bdc06a7_u32, 0xc19bf174_u32,
    0xe49b69c1_u32, 0xefbe4786_u32, 0x0fc19dc6_u32, 0x240ca1cc_u32, 0x2de92c6f_u32, 0x4a7484aa_u32, 0x5cb0a9dc_u32, 0x76f988da_u32,
    0x983e5152_u32, 0xa831c66d_u32, 0xb00327c8_u32, 0xbf597fc7_u32, 0xc6e00bf3_u32, 0xd5a79147_u32, 0x06ca6351_u32, 0x14292967_u32,
    0x27b70a85_u32, 0x2e1b2138_u32, 0x4d2c6dfc_u32, 0x53380d13_u32, 0x650a7354_u32, 0x766a0abb_u32, 0x81c2c92e_u32, 0x92722c85_u32,
    0xa2bfe8a1_u32, 0xa81a664b_u32, 0xc24b8b70_u32, 0xc76c51a3_u32, 0xd192e819_u32, 0xd6990624_u32, 0xf40e3585_u32, 0x106aa070_u32,
    0x19a4c116_u32, 0x1e376c08_u32, 0x2748774c_u32, 0x34b0bcb5_u32, 0x391c0cb3_u32, 0x4ed8aa4a_u32, 0x5b9cca4f_u32, 0x682e6ff3_u32,
    0x748f82ee_u32, 0x78a5636f_u32, 0x84c87814_u32, 0x8cc70208_u32, 0x90befffa_u32, 0xa4506ceb_u32, 0xbef9a3f7_u32, 0xc67178f2_u32,
  ]

  # Returns the lowercase hex SHA-256 of *data*.
  def self.hexdigest(data : Bytes) : String
    h = StaticArray[0x6a09e667_u32, 0xbb67ae85_u32, 0x3c6ef372_u32, 0xa54ff53a_u32,
      0x510e527f_u32, 0x9b05688c_u32, 0x1f83d9ab_u32, 0x5be0cd19_u32]
    length = data.size
    padded = Bytes.new(((length + 9 + 63) // 64) * 64)
    padded.copy_from(data)
    padded[length] = 0x80_u8
    bits = length.to_u64 * 8
    8.times { |index| padded[padded.size - 1 - index] = (bits >> (8 * index)).to_u8! }
    w = StaticArray(UInt32, 64).new(0_u32)
    (padded.size // 64).times do |block|
      16.times { |index| w[index] = IO::ByteFormat::BigEndian.decode(UInt32, padded[block * 64 + index * 4, 4]) }
      (16...64).each do |index|
        s0 = w[index - 15].rotate_right(7) ^ w[index - 15].rotate_right(18) ^ (w[index - 15] >> 3)
        s1 = w[index - 2].rotate_right(17) ^ w[index - 2].rotate_right(19) ^ (w[index - 2] >> 10)
        w[index] = w[index - 16] &+ s0 &+ w[index - 7] &+ s1
      end
      a, b, c, d, e, f, g, hh = h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7]
      64.times do |index|
        t1 = hh &+ (e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25)) &+ ((e & f) ^ (~e & g)) &+ K[index] &+ w[index]
        t2 = (a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22)) &+ ((a & b) ^ (a & c) ^ (b & c))
        hh, g, f, e, d, c, b, a = g, f, e, d &+ t1, c, b, a, t1 &+ t2
      end
      h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d
      h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
    end
    String.build { |io| h.each { |word| io << word.to_s(16).rjust(8, '0') } }
  end
end
