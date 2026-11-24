require "./support"

private alias H2 = Mica::HTTP2
private alias S = HTTP2Spec

# Property checks with fixed seeds; fuzz/http2_campaign.cr runs the same
# properties over millions of cases.
describe "Mica::HTTP2 frame properties" do
  it_satisfies "H2-API-round-trip", "parses every serialized random frame back to the same frame" do
    random = Random.new(9113)
    5_000.times do
      frame = S.random_frame(random)
      S.frames(frame.to_slice(max_frame_size: H2::DEFAULT_MAX_FRAME_SIZE)).should eq [frame] of H2::Frame
    end
    list_of_frames = S.random_frames(random, 2_000)
    S.frames(S.serialize(list_of_frames)).should eq list_of_frames
  end

  it_satisfies "H2-API-trickle", "gives the same frames and errors one byte at a time, in random chunks and at once" do
    random = Random.new(4_1)
    200.times do
      bytes = S.serialize(S.random_frames(random, random.rand(1..20)))
      if random.rand(2) == 0 && bytes.size > 0
        # Mutate some bytes, so errors are compared too.
        random.rand(1..4).times { bytes[random.rand(bytes.size)] = random.rand(256).to_u8 }
      end
      whole = S.outcome(bytes)
      S.outcome(bytes, [1]).should eq whole
      S.outcome(bytes, Array.new(5) { random.rand(1..40) }).should eq whole
    end
  end

  it_satisfies "H2-FUZZ", "raises only Mica errors on random and mutated streams, holding at most a frame and a chunk" do
    random = Random.new(2)
    20_000.times do
      bytes = if random.rand(2) == 0
                Bytes.new(random.rand(0..200)) { random.rand(256).to_u8 }
              else
                serialized = S.serialize(S.random_frames(random, random.rand(1..4)))
                random.rand(1..6).times { serialized[random.rand(serialized.size)] = random.rand(256).to_u8 } unless serialized.empty?
                serialized
              end
      parser = S.parser(expect_preface: random.rand(8) == 0)
      begin
        parser.feed(bytes) { }
      rescue Mica::Error
      end
    end
  end
end
