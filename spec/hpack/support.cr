require "../spec_helper"
require "json"

private alias Header = Mica::HPACK::Header

# Helpers shared by the HPACK specs.
module HPACKSpec
  # One case of an hpack-test-case story.
  struct StoryCase
    include JSON::Serializable

    getter seqno : Int32 = -1
    getter header_table_size : Int32? = nil
    getter wire : String = ""
    getter headers : Array(Hash(String, String)) = [] of Hash(String, String)

    # Returns the expected fields as name and value pairs, in order.
    def list_of_fields : Array({String, String})
      headers.flat_map { |entry| entry.map { |name, value| {name, value} } }
    end
  end

  # One hpack-test-case story: cases that share one compression context.
  struct Story
    include JSON::Serializable

    getter cases : Array(StoryCase) = [] of StoryCase
  end

  # Limits that let every corpus story through (the largest table size the
  # corpus advertises is 16,384).
  CORPUS_LIMITS = Mica::HPACK::DecodeLimits.custom(max_header_list_bytes: 1_048_576,
    max_header_block_bytes: 1_048_576, max_table_bytes: 65_536)

  def self.hex(text : String) : Bytes
    text.hexbytes
  end

  def self.fields(list : Array(Header)) : Array({String, String})
    list.map { |header| {header.name, header.value} }
  end

  def self.headers(list : Array({String, String})) : Array(Header)
    list.map { |(name, value)| Header.new(name, value) }
  end

  def self.decoder(limits : Mica::HPACK::DecodeLimits = Mica::HPACK::DecodeLimits::PUBLIC_SERVER) : Mica::HPACK::Decoder
    Mica::HPACK::Decoder.new(limits: limits)
  end

  # Returns a random header list drawn from a small vocabulary, so names and
  # fields repeat and the dynamic table is exercised.
  def self.random_list(random : Random) : Array(Header)
    names = {":method", ":path", ":authority", ":status", "accept", "cookie", "set-cookie", "x-trace", "user-agent",
             "content-type", "authorization", "x-#{random.rand(50)}", "custom-key"}
    Array.new(random.rand(0..12)) do
      name = names[random.rand(names.size)]
      value = case random.rand(4)
              when 0 then "GET"
              when 1 then "/#{random.rand(30)}"
              when 2 then String.new(Bytes.new(random.rand(0..40)) { random.rand(256).to_u8 })
              else        "v#{random.rand(100)}" * random.rand(1..4)
              end
      Header.new(name, value, random.rand(16) == 0)
    end
  end
end
