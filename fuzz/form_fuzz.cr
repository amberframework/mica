# The Mica::Form layer over Mica::Testing::ByteMutator and FuzzCampaign,
# shared by spec/form/fuzz_spec.cr and fuzz/form_campaign.cr.
require "uri"
require "../src/mica"
require "../src/mica/testing"

module FormFuzz
  SEEDS = [
    "user[name]=Ada+Lovelace&user[email]=ada%40example.com&user[admin]=0&user[admin]=1",
    "tags[]=crystal&tags[]=amber&tags[]=&items[0][name]=a&items[0][qty]=2&items[3][name]=d",
    "a[][x]=1&a[][y]=2&a[][x]=3&m[][]=1&m[][0]=2",
    "user.name=John&user.address.city=NYC&q=caf%C3%A9+%F0%9F%98%80",
    "&&a=b&&c&d=%zz%4%41&e==f&%=%&+=+",
    "csrf_token=abc%2Bdef%2F%3D&utf8=%E2%9C%93&commit=Save",
    "x[a][b][c][d][e][f][g]=deep&x[a][b][c][d][e][f][h]=deep2",
    "%EF%BB%BFbom=%EF%BB%BF&nul=%00&ctl=%01%7F&nonchar=%EF%BF%BF",
  ].map(&.to_slice)

  TOKENS = ["&", "=", "+", "%", "%2", "%41", "%C3%A9", "%C3", "%FF", "%ZZ", "[", "]", "[]", "[0]", "[999]",
            "[9999999999]", "[007]", "[x]", ".", "..", "a", "a=1", "a[b]=1", "a[]=1", "a[0]=1", "a=", "=",
            "%5B", "%5D", "%26", "%3D", "\xC3\xA9", "\xFF"].map(&.to_slice)

  MUTATOR = Mica::Testing::ByteMutator.new(SEEDS, TOKENS)

  # Most operations recorded past the allowance: Form charges in pieces
  # of at most one 64 KiB scan window (Mica::Form::Metering::SCAN_CHUNK),
  # plus the small fixed charges around it.
  OVERRUN_SLACK = 70_000_i64

  # A tight budget and small limits used for one case in four, so budget
  # and limit trips happen and their containment is checked.
  TIGHT_LIMITS = Mica::Form::Limits.new(
    max_input_bytes: 256_i64, max_pairs: 8, max_key_depth: 4, max_array_index: 8, max_array_slots: 16,
    work_budget: Mica::Core::WorkBudget.new(operations_per_unit: 2, base_operations: 100))

  # Parses *bytes* in memory and through a trickle IO and compares the two;
  # for accepted input also checks the serializer round trip and that
  # stdlib URI::Params finds the same pairs. Raises (making the campaign
  # record a crash) on anything but a Mica::Error.
  def self.trial(bytes : Bytes, iteration : Int32) : Mica::Testing::FuzzCampaign::Trial
    limits = iteration % 4 == 3 ? TIGHT_LIMITS : Mica::Form::Limits::REQUEST_BODY
    meter = Mica::Core::WorkMeter.new(limits.work_budget)
    in_memory = outcome(bytes, limits, meter)
    chunk = 1 + iteration % 7
    streamed = outcome(TrickleIO.new(bytes, chunk), limits, Mica::Core::WorkMeter.new(limits.work_budget))
    failures = [] of String
    if in_memory[0] != streamed[0]
      failures << "Bytes and #{chunk}-byte IO disagree: #{in_memory[0][0, 200].inspect} vs #{streamed[0][0, 200].inspect}"
    end
    error = in_memory[1]
    failures.concat(pair_checks(bytes)) unless iteration % 4 == 3
    Mica::Testing::FuzzCampaign::Trial.new(in_memory[0], error, meter, failures)
  end

  # The nested value, or the error with its position.
  private def self.outcome(source : Bytes | IO, limits : Mica::Form::Limits, meter : Mica::Core::WorkMeter) : {String, Mica::Error?}
    value = Mica::Form.parse(source, limits: limits, meter: meter)
    {value.inspect, nil}
  rescue error : Mica::Error
    position = error.is_a?(Mica::ParseError) ? error.byte_offset : -1
    {"#{error.class}: #{error.message} @#{position}", error}
  end

  # Checks the pairs of input the pair parser accepts: the serializer
  # round trip is stable, and stdlib URI::Params (the differential oracle)
  # finds the same pairs. Input the pair parser rejects has nothing to
  # compare (stdlib passes invalid UTF-8 through; see
  # conformance/form/run.cr).
  private def self.pair_checks(bytes : Bytes) : Array(String)
    failures = [] of String
    unbounded = Mica::Form::Limits.unbounded(reason: "fuzz oracle comparison")
    begin
      pairs = Mica::Form::Pairs.parse(bytes, limits: unbounded)
    rescue Mica::Error
      return failures
    end
    list = pairs.map { |pair| {pair.field_name, pair.field_value} }
    again = Mica::Form::Pairs.parse(pairs.to_s, limits: unbounded).map { |pair| {pair.field_name, pair.field_value} }
    failures << "serializer round trip changed #{list.inspect[0, 200]}" unless again == list
    stdlib = [] of {String, String}
    URI::Params.parse(String.new(bytes)) { |name, value| stdlib << {name, value} }
    # Stdlib also splits on ';' (the HTML 4 recommendation); WHATWG splits
    # on '&' only. That is the one known difference, so input holding a
    # ';' is not compared.
    unless stdlib == list || bytes.includes?(0x3B_u8)
      failures << "stdlib URI::Params differs: #{stdlib.inspect[0, 200]} vs #{list.inspect[0, 200]}"
    end
    failures
  end

  # An IO that returns at most *chunk* bytes per read.
  class TrickleIO < IO
    def initialize(@bytes : Bytes, @chunk : Int32)
      @offset = 0
    end

    def read(slice : Bytes) : Int32
      count = Math.min(Math.min(@chunk, slice.size), @bytes.size - @offset)
      return 0 if count <= 0
      slice[0, count].copy_from(@bytes[@offset, count])
      @offset += count
      count
    end

    def write(slice : Bytes) : Nil
      raise IO::Error.new("read-only")
    end
  end
end
