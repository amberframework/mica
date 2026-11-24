#!/usr/bin/ruby
# frozen_string_literal: true

# Packs the hpack-test-case stories (fetched by
# conformance/hpack/fetch_test_case.rb) into one binary file both runners
# read, so they decode the same blocks in the same order:
#
#   /usr/bin/ruby bench/hpack/make_corpus.rb OUT
#
# Records: 'S' starts a story (a new decoder at 4,096 bytes); 'T' u32 is a
# SETTINGS_HEADER_TABLE_SIZE change; 'B' u32 len, bytes is one block.
# Integers are big-endian.
require 'json'

root = File.expand_path('../../conformance/hpack-test-case/data', __dir__)
abort "run conformance/hpack/fetch_test_case.rb first" unless Dir.exist?(root)
out = File.open(ARGV.fetch(0), 'wb')
stories = 0
blocks = 0
bytes = 0
Dir.children(root).sort.each do |implementation|
  next if implementation == 'raw-data'
  Dir.glob(File.join(root, implementation, 'story_*.json')).sort.each do |path|
    stories += 1
    out.write('S')
    JSON.parse(File.read(path))['cases'].each do |kase|
      if (size = kase['header_table_size'])
        out.write('T', [size].pack('N'))
      end
      wire = [kase['wire']].pack('H*')
      out.write('B', [wire.bytesize].pack('N'), wire)
      blocks += 1
      bytes += wire.bytesize
    end
  end
end
out.close
puts "stories=#{stories} blocks=#{blocks} block_bytes=#{bytes}"
