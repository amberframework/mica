# stdlib XML (libxml2) side of the benchmark, strict options (NONET, no
# RECOVER). Build with:
#   crystal-alpha build --release bench/bench_stdlib.cr -o bench/bin/bench_stdlib
require "xml"
require "./harness"

S3_NAMESPACES = {"s3" => "http://s3.amazonaws.com/doc/2006-03-01/"}
STRICT        = XML::ParserOptions::NONET

INPUTS = {} of String => String

def input(path : String) : String
  INPUTS[path] ||= File.read(path)
end

BenchHarness.run("libxml2") do |workload, path, verify|
  case workload
  when "dom"
    document = XML.parse(input(path), STRICT)
    verify ? document.xpath_float("count(//*)").to_i64 : 0_i64
  when "reader"
    File.open(path) do |file|
      reader = XML::Reader.new(file, STRICT)
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
      abort "reader errors: #{reader.errors.first.message}" unless reader.errors.empty?
      checksum
    end
  when "xpath"
    document = XML.parse(input(path), STRICT)
    document.xpath_nodes("//s3:Contents/s3:Key", S3_NAMESPACES).sum(0_i64, &.content.bytesize.to_i64)
  else
    abort "unknown workload #{workload}"
  end
end
