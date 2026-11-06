require "../spec_helper"

describe "Mica::VERSION" do
  it "matches shard.yml" do
    shard_text = File.read(File.join(__DIR__, "..", "..", "shard.yml"))
    shard_text.should contain("\nversion: #{Mica::VERSION}\n")
  end
end
