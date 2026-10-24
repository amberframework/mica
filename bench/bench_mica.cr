# Mica side of the benchmark. Build with:
#   crystal-alpha build --release bench/bench_mica.cr -o bench/bin/bench_mica
require "../src/mica"
require "./harness"

S3_NAMESPACES = {"s3" => "http://s3.amazonaws.com/doc/2006-03-01/"}

# The input string is read once, outside the timed region, as in the
# stdlib program.
INPUTS = {} of String => String

def input(path : String) : String
  INPUTS[path] ||= File.read(path)
end

BenchHarness.run("mica") do |workload, path, verify|
  case workload
  when "dom"
    document = Mica.parse(input(path))
    verify ? document.xpath_float("count(//*)").to_i64 : 0_i64
  when "reader"
    File.open(path) do |file|
      reader = Mica::Reader.new(file)
      checksum = 0_i64
      while reader.read
        case reader.node_type
        when .element?
          checksum += 1 + reader.name.bytesize
          if reader.move_to_first_attribute
            loop do
              checksum += reader.name.bytesize + reader.value.bytesize
              break unless reader.move_to_next_attribute
            end
            reader.move_to_element
          end
        when .text?, .cdata?
          checksum += reader.value.bytesize
        end
      end
      checksum
    end
  when "xpath"
    document = Mica.parse(input(path))
    document.xpath_nodes("//s3:Contents/s3:Key", S3_NAMESPACES).sum(0_i64, &.content.bytesize.to_i64)
  else
    abort "unknown workload #{workload}"
  end
end
