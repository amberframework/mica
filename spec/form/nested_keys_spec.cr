require "../spec_helper"

private LIMITS = Mica::Form::Limits::REQUEST_BODY

private def nested(input : String, limits : Mica::Form::Limits = LIMITS,
                   options : Mica::Form::NestedKeys::Options = Mica::Form::NestedKeys::Options.new) : Mica::Form::Value
  Mica::Form.parse(input, limits: limits, options: options)
end

# Renders a value compactly: strings bare, nil as `~`.
private def shape(value : Mica::Form::Value) : String
  String.build { |io| write_shape(value, io) }
end

private def write_shape(value : Mica::Form::Value, io : IO) : Nil
  if hash = value.as_h?
    io << '{'
    hash.each_with_index do |(key, child), index|
      io << ',' if index > 0
      io << key << ':'
      write_shape(child, io)
    end
    io << '}'
  elsif array = value.as_a?
    io << '['
    array.each_with_index do |child, index|
      io << ',' if index > 0
      write_shape(child, io)
    end
    io << ']'
  elsif string = value.as_s?
    io << string
  else
    io << '~'
  end
end

describe Mica::Form::NestedKeys do
  describe "grammar" do
    it_satisfies "FORM-KEY-PLAIN", "maps a key without brackets or dots to one hash key" do
      shape(nested("name=Ada&a]b=1")).should eq("{name:Ada,a]b:1}")
    end

    it_satisfies "FORM-KEY-DOT", "splits dot keys into hash keys, and keeps them whole with dot notation off" do
      shape(nested("user.name=John&user.address.city=NYC&items.0=x")).should eq("{user:{name:John,address:{city:NYC}},items:{0:x}}")
      off = Mica::Form::NestedKeys::Options.new(dot_notation: false)
      shape(nested("user.name=John", options: off)).should eq("{user.name:John}")
      shape(nested("a[b.c]=1&d.e[f]=2")).should eq("{a:{b.c:1},d.e:{f:2}}")
    end

    it_satisfies "FORM-KEY-DOT-EMPTY", "rejects an empty part between dots" do
      {"a..b=1", ".a=1", "a.=1"}.each do |input|
        expect_raises(Mica::Form::KeySyntaxError, "empty part between dots") { nested(input) }
      end
    end

    it_satisfies "FORM-KEY-HEAD", "rejects a key that starts with a bracket" do
      expect_raises(Mica::Form::KeySyntaxError, "starts with '['") { nested("[a]=1") }
      expect_raises(Mica::Form::KeySyntaxError, "starts with '['") { nested("[]=1") }
    end

    it_satisfies "FORM-KEY-SEGMENTS", "rejects anything after the head that is not a complete segment" do
      expect_raises(Mica::Form::KeySyntaxError, "unclosed '['") { nested("a[b=1") }
      expect_raises(Mica::Form::KeySyntaxError, "do not start a segment") { nested("a[b]c=1") }
      expect_raises(Mica::Form::KeySyntaxError, "do not start a segment") { nested("a[b]]=1") }
      expect_raises(Mica::Form::KeySyntaxError, "'[' inside a segment") { nested("a[b[c]]=1") }
      shape(nested("a[b][c][d]=1")).should eq("{a:{b:{c:{d:1}}}}")
    end

    it_satisfies "FORM-KEY-INDEX", "treats canonical decimal segments as indices and other segments as hash keys" do
      shape(nested("a[0]=x&a[1]=y")).should eq("{a:[x,y]}")
      shape(nested("b[007]=x&b[1a]=y&b[-1]=z")).should eq("{b:{007:x,1a:y,-1:z}}")
      shape(nested("c[0][0]=x&c[0][1]=y&c[1][k]=z")).should eq("{c:[[x,y],{k:z}]}")
    end

    it_satisfies "FORM-KEY-APPEND-LAST", "appends values for a trailing []" do
      shape(nested("tags[]=a&tags[]=b&tags[]=")).should eq("{tags:[a,b,]}")
      shape(nested("t[0]=a&t[]=b&t[5]=c&t[]=d")).should eq("{t:[a,b,~,~,~,c,d]}")
    end

    it_satisfies "FORM-KEY-APPEND-HASH", "continues the last hash after [] unless it already holds the rest of the key" do
      shape(nested("a[][x]=1&a[][y]=2&a[][x]=3")).should eq("{a:[{x:1,y:2},{x:3}]}")
      shape(nested("p[][n]=1&p[][m][k]=2&p[][m][j]=3&p[][m][k]=4")).should eq("{p:[{n:1,m:{k:2,j:3}},{m:{k:4}}]}")
      shape(nested("q[][x][]=1&q[][x][]=2")).should eq("{q:[{x:[1,2]}]}")
      shape(nested("r[]=s&r[][x]=1")).should eq("{r:[s,{x:1}]}")
    end

    it_satisfies "FORM-KEY-APPEND-ARRAY", "starts a new array for [] before an index or another []" do
      shape(nested("m[][]=1&m[][]=2&m[][0]=3")).should eq("{m:[[1],[2],[3]]}")
    end

    it_satisfies "FORM-KEY-SPARSE", "keeps sparse indices sparse while building and fills gaps with nil" do
      value = nested("values[0]=a&values[2]=c&values[5]=f")
      shape(value).should eq("{values:[a,~,c,~,~,f]}")
      value["values"][1].empty_slot?.should be_true
      value["values"].size.should eq(6)
    end

    it_satisfies "FORM-KEY-CONFLICT", "raises KeyConflictError when keys need different kinds of value" do
      {
        "a=1&a[b]=2"             => "needs a hash where a string already is",
        "a[b]=1&a=2"             => "assigns a value where a hash already is",
        "a[0]=1&a[b]=2"          => "needs a hash where an array already is",
        "a[b]=1&a[0]=2"          => "needs an array where a hash already is",
        "a[]=1&a[0][b]="         => "needs a hash where a string already is",
        "a[0]=1&a[]=2&a[1][c]=3" => "needs a hash where a string already is",
      }.each do |input, message|
        expect_raises(Mica::Form::KeyConflictError, message) { nested(input) }
      end
    end

    it_satisfies "FORM-KEY-DUPLICATE", "keeps the last value for a repeated path, or rejects it on request" do
      shape(nested("user[admin]=0&user[admin]=1&a[0]=x&a[0]=y")).should eq("{user:{admin:1},a:[y]}")
      reject = Mica::Form::NestedKeys::Options.new(duplicate_leaves: Mica::Form::NestedKeys::DuplicateLeaves::Reject)
      error = expect_raises(Mica::Form::KeyConflictError, "repeats a key") { nested("a=1&b=2&a=3", options: reject) }
      error.byte_offset.should eq(8)
    end

    it_satisfies "FORM-KEY-ORDER", "keeps hash keys in first-seen order" do
      nested("z=1&a=2&m[y]=3&m[b]=4&z=5")["m"].as_h.keys.should eq(["y", "b"])
      nested("z=1&a=2&m[y]=3&m[b]=4&z=5").as_h.keys.should eq(["z", "a", "m"])
    end

    it_satisfies "FORM-KEY-ERROR-POSITION", "positions key errors at the offending pair in the original input" do
      error = expect_raises(Mica::Form::KeyConflictError) { nested("ok=1&a=1&a%5Bb%5D=2") }
      error.byte_offset.should eq(9)
      error = expect_raises(Mica::Form::KeySyntaxError) { nested("x=1&a[b=2") }
      error.byte_offset.should eq(4)
    end
  end

  describe "Amber fixtures" do
    it_satisfies "FORM-KEY-AMBER-FIXTURES", "reproduces Amber V2's nested parameter specs as strings" do
      shape(nested("user[name]=John&user[age]=30")).should eq("{user:{name:John,age:30}}")
      shape(nested("user[address][city]=NYC&user[address][zip]=10001")).should eq("{user:{address:{city:NYC,zip:10001}}}")
      shape(nested("user.name=John&user.address.city=NYC")).should eq("{user:{name:John,address:{city:NYC}}}")
      shape(nested("items[0]=first&items[1]=second&items[2]=third")).should eq("{items:[first,second,third]}")
      shape(nested("values[0]=a&values[2]=c&values[5]=f")).should eq("{values:[a,~,c,~,~,f]}")
      shape(nested("user[tags][0]=admin&user[tags][1]=user&user[name]=John")).should eq("{user:{tags:[admin,user],name:John}}")
      shape(nested("tags[]=ruby&tags[]=crystal")).should eq("{tags:[ruby,crystal]}")
    end
  end

  describe "limits" do
    it_satisfies "MICA-FORM-LIMIT-KEY-DEPTH", "rejects keys deeper than max_key_depth, in brackets and in dots" do
      limits = Mica::Form::Limits.new(max_key_depth: 3)
      shape(nested("a[b][c]=1&x.y.z=2", limits)).should eq("{a:{b:{c:1}},x:{y:{z:2}}}")
      error = expect_raises(Mica::LimitExceededError, "max_key_depth (3)") { nested("ok=1&a[b][c][d]=1", limits) }
      error.byte_offset.should eq(5)
      expect_raises(Mica::LimitExceededError, "max_key_depth (3)") { nested("a.b.c.d=1", limits) }
    end

    it_satisfies "MICA-FORM-LIMIT-ARRAY-INDEX", "rejects indices and appends above max_array_index without allocating" do
      nested("a[1000]=x")["a"].as_a.size.should eq(1001)
      {"a[1001]=x", "a[999999999]=x", "a[9999999999]=x", "a[#{"9" * 400}]=x"}.each do |input|
        error = expect_raises(Mica::LimitExceededError, "max_array_index (1000)") { nested(input) }
        error.byte_offset.should eq(0)
      end
      limits = Mica::Form::Limits.new(max_array_index: 2)
      expect_raises(Mica::LimitExceededError, "max_array_index (2)") { nested("t[]=1&t[]=2&t[]=3&t[]=4", limits) }
    end

    it_satisfies "MICA-FORM-LIMIT-ARRAY-SLOTS", "caps the array slots of the whole result" do
      limits = Mica::Form::Limits.new(max_array_slots: 1_500)
      nested("a[999]=x", limits)
      error = expect_raises(Mica::LimitExceededError, "max_array_slots (1500)") { nested("a[999]=x&b[999]=y", limits) }
      error.byte_offset.should eq(9)
    end

    it "trips max_array_slots, not an overflow, for an index of Int32::MAX" do
      limits = Mica::Form::Limits.new(max_array_index: Int32::MAX)
      error = expect_raises(Mica::LimitExceededError, "max_array_slots (10000)") { nested("a[2147483647]=x", limits) }
      error.byte_offset.should eq(0)
    end

    it_satisfies "MICA-FORM-LIMIT-INPUT", "counts the bytes of pairs made in code against max_input_bytes" do
      limits = Mica::Form::Limits.new(max_input_bytes: 8_i64)
      Mica::Form::NestedKeys.build([Mica::Form::Pair.new("a", "1234567")], limits: limits)["a"].as_s.should eq("1234567")
      list_of_pairs = [Mica::Form::Pair.new("a", "1234"), Mica::Form::Pair.new("b", "1234", 6_i64)]
      error = expect_raises(Mica::LimitExceededError, "max_input_bytes (8)") do
        Mica::Form::NestedKeys.build(list_of_pairs, limits: limits)
      end
      error.byte_offset.should eq(6)
    end

    it "counts max_pairs when built from pairs made in code" do
      list_of_pairs = (1..3).map { |index| Mica::Form::Pair.new("k#{index}", "v") }
      limits = Mica::Form::Limits.new(max_pairs: 2)
      expect_raises(Mica::LimitExceededError, "max_pairs (2)") do
        Mica::Form::NestedKeys.build(list_of_pairs, limits: limits)
      end
    end

    it "refuses use after a failed add or after finish" do
      builder = Mica::Form::NestedKeys.new(limits: LIMITS)
      builder.add(Mica::Form::Pair.new("a", "1"))
      expect_raises(Mica::Form::KeyConflictError) { builder.add(Mica::Form::Pair.new("a[b]", "2")) }
      expect_raises(ArgumentError, "failed add") { builder.add(Mica::Form::Pair.new("c", "3")) }
      finished = Mica::Form::NestedKeys.new(limits: LIMITS)
      finished.finish
      expect_raises(ArgumentError, "after finish") { finished.add(Mica::Form::Pair.new("c", "3")) }
    end
  end

  describe Mica::Form::Value do
    it "offers typed and nilable accessors" do
      value = nested("s=x&h[k]=v&a[]=1")
      value["s"].as_s.should eq("x")
      value["s"].as_h?.should be_nil
      value["h"]["k"].as_s.should eq("v")
      value["a"][0].as_s.should eq("1")
      value["a"][5]?.should be_nil
      value["missing"]?.should be_nil
      expect_raises(KeyError, "missing") { value["missing"] }
      expect_raises(TypeCastError, "Expected a form Array") { value["s"].as_a }
      expect_raises(IndexError) { value["a"][5] }
      value.should eq(nested("s=x&h[k]=v&a[]=1"))
    end
  end
end
