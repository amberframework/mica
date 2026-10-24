# Seeded mutation generator shared by spec/mica/fuzz_spec.cr and
# fuzz/differential.cr. Every case is a pure function of (seed, iteration),
# so any failure can be replayed exactly.
module Fuzz
  SEEDS = [
    %(<?xml version="1.0" encoding="UTF-8"?>\n<root a="1" b='two'><child>text</child><empty/></root>),
    %(<!DOCTYPE r [<!ENTITY e "<i>x</i>&amp;"><!ENTITY t "plain"><!ATTLIST r d CDATA "def" n NMTOKENS #IMPLIED>]><r n=" a  b ">&e;&t;&#65;&#x42;</r>),
    %(<r xmlns="urn:d" xmlns:p="urn:p"><p:e p:a="1" b="2"><x xmlns=""/></p:e></r>),
    %(<a><![CDATA[<not>markup]]]]><![CDATA[>]]><!-- comment --><?pi data?></a>),
    %(<a>line1\r\nline2\rline3\n<b attr="x\ty\r\nz"/></a>),
    %(<?xml version="1.0" standalone="yes"?><!DOCTYPE a [<!ELEMENT a (b|c)*><!ELEMENT b EMPTY><!ATTLIST b id ID #REQUIRED><!NOTATION n PUBLIC "pub">]><a><b id="i1"/></a>),
    %(<!DOCTYPE a [<!ENTITY % pe "<!ENTITY g 'from-pe'>">%pe;<!ENTITY ext SYSTEM "ext.xml">]><a>&g;&ext;</a>),
    %(<feed><title>Café — Größe 😀</title><entry id="1"><summary>a &lt; b &gt; c</summary></entry></feed>),
    %(<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Contents><Key>a.txt</Key><ETag>&quot;abc&quot;</ETag><Size>1</Size></Contents></ListBucketResult>),
    %(<rss version="2.0"><channel><item><title>T</title><description><![CDATA[<p>Hi</p>]]></description></item></channel></rss>),
    %(<a b="&#x10FFFF;&#9;" c='"'><d e="'"/></a>),
    %(<!DOCTYPE doc [<!ELEMENT doc (#PCDATA|e)*><!ENTITY x "&#60;e/&#62;">]><doc>&x;</doc>),
    %(<root>#{"<n>" * 40}deep#{"</n>" * 40}</root>),
    %(<?xml version="1.0"?><!-- c --><?pi?><r/><!-- after --><?pi after?>),
  ]

  TOKENS = ["<", ">", "&", ";", "&amp;", "&#", "&#x", "]]>", "<!--", "-->", "<![CDATA[", "<?", "?>", "</",
            "/>", "\"", "'", "=", " ", "\t", "\r", "\n", "<!ENTITY ", "<!DOCTYPE ", "<!ATTLIST ", "%", "&e;",
            "xmlns:", "xmlns=\"\"", ":", "\u0000", "ÿ", "￾", "😀", "\xEF\xBB\xBF", "<a>", "</a>"]

  RAW_BYTES = [0x00_u8, 0x80_u8, 0xC0_u8, 0xC3_u8, 0xED_u8, 0xF4_u8, 0xF8_u8, 0xFE_u8, 0xFF_u8, 0x0D_u8, 0x1F_u8]

  # Returns the bytes for case *iteration* under *seed*.
  def self.case_bytes(seed : Int64, iteration : Int32) : Bytes
    random = Random::PCG32.new(seed.to_u64!, iteration.to_u64)
    bytes = SEEDS[random.rand(SEEDS.size)].to_slice.dup
    (1 + random.rand(4)).times { bytes = mutate(bytes, random) }
    if random.rand(20) == 0
      bytes = to_utf16(bytes, random.next_bool)
    end
    bytes
  end

  def self.mutate(bytes : Bytes, random : Random) : Bytes
    return Bytes[0x3C] if bytes.empty?
    position = random.rand(bytes.size + 1)
    case random.rand(8)
    when 0 # flip one bit
      copy = bytes.dup
      index = random.rand(copy.size)
      copy[index] ^= (1_u8 << random.rand(8))
      copy
    when 1 # insert a token
      insert(bytes, position, TOKENS[random.rand(TOKENS.size)].to_slice)
    when 2 # delete a range
      start = random.rand(bytes.size)
      remove(bytes, start, 1 + random.rand(Math.min(16, bytes.size - start)))
    when 3 # duplicate a range
      start = random.rand(bytes.size)
      length = 1 + random.rand(Math.min(32, bytes.size - start))
      insert(bytes, position, bytes[start, length].dup)
    when 4 # truncate
      bytes[0, random.rand(bytes.size)].dup
    when 5 # splice with another seed
      other = SEEDS[random.rand(SEEDS.size)].to_slice
      cut = random.rand(other.size)
      insert(bytes[0, Math.min(position, bytes.size)].dup, Math.min(position, bytes.size), other[cut, other.size - cut])
    when 6 # raw byte
      insert(bytes, position, Bytes[RAW_BYTES[random.rand(RAW_BYTES.size)]])
    else # swap two bytes
      copy = bytes.dup
      first = random.rand(copy.size)
      second = random.rand(copy.size)
      copy[first], copy[second] = copy[second], copy[first]
      copy
    end
  end

  def self.insert(bytes : Bytes, position : Int32, extra : Bytes) : Bytes
    position = Math.min(position, bytes.size)
    result = Bytes.new(bytes.size + extra.size)
    result.copy_from(bytes.to_unsafe, position)
    (result + position).copy_from(extra.to_unsafe, extra.size)
    (result + position + extra.size).copy_from(bytes.to_unsafe + position, bytes.size - position)
    result
  end

  def self.remove(bytes : Bytes, start : Int32, length : Int32) : Bytes
    length = Math.min(length, bytes.size - start)
    result = Bytes.new(bytes.size - length)
    result.copy_from(bytes.to_unsafe, start)
    (result + start).copy_from(bytes.to_unsafe + start + length, bytes.size - start - length)
    result
  end

  # Encodes valid UTF-8 as UTF-16 with a BOM; invalid sequences become
  # lone surrogates so the decoder's error path is exercised too.
  def self.to_utf16(bytes : Bytes, big_endian : Bool) : Bytes
    io = IO::Memory.new
    io.write(big_endian ? Bytes[0xFE, 0xFF] : Bytes[0xFF, 0xFE])
    String.new(bytes).each_char do |char|
      code = char == Char::REPLACEMENT ? 0xDC00 : char.ord
      units = code >= 0x10000 ? [0xD800 + ((code - 0x10000) >> 10), 0xDC00 + ((code - 0x10000) & 0x3FF)] : [code]
      units.each do |unit|
        high = (unit >> 8).to_u8
        low = (unit & 0xFF).to_u8
        io.write(big_endian ? Bytes[high, low] : Bytes[low, high])
      end
    end
    io.to_slice
  end
end
