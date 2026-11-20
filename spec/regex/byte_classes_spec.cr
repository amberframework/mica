require "../spec_helper"

private def byte_classes_of(source : String) : Mica::Regex::ByteClasses
  expression = Mica::Regex::Expression.new(source, compile_limits: Mica::Regex::CompileLimits::TRUSTED_PATTERN)
  Mica::Regex::ByteClasses.new(expression.program)
end

describe Mica::Regex::ByteClasses do
  describe "#class_size" do
    it "counts the byte values of each class, which together are all 256" do
      {"(a+)|(b+)|(c+)", "[^\"]*", "(?s).*", "\\s+x", "abc"}.each do |source|
        byte_classes = byte_classes_of(source)
        sizes = Array.new(byte_classes.class_count) { |class_index| byte_classes.class_size(class_index) }
        sizes.sum.should eq(256)
        sizes.each_with_index do |size, class_index|
          (0..255).count { |byte| byte_classes.class_of(byte.to_u8) == class_index }.should eq(size)
        end
      end
    end
  end
end
