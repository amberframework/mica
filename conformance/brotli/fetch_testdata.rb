#!/usr/bin/ruby
# frozen_string_literal: true

# Fetches google/brotli's conformance files (tests/testdata) at a pinned
# commit and verifies each one against MANIFEST.tsv beside this script.
#
#   /usr/bin/ruby conformance/brotli/fetch_testdata.rb
#
# Files land in conformance/brotli-testdata/ (git-ignored). A file whose
# sha256 differs from the manifest is deleted and the script exits
# non-zero. The pin is the commit the tag v1.2.1 points to; the release
# tarball leaves tests/testdata out, so the files come one by one from
# raw.githubusercontent.com at that commit.
#
# Only the Ruby standard library is used (system /usr/bin/ruby).

require 'digest'
require 'fileutils'
require 'net/http'
require 'uri'

COMMIT = 'db24a98aed38a16de78cc05ca15cdd8dc2a0d92d'
BASE = "https://raw.githubusercontent.com/google/brotli/#{COMMIT}/tests/testdata/"
USER_AGENT = 'AgentC-Consulting-research/1.0 (+https://agentc.consulting; agent_c@agentc.consulting)'
TARGET = File.expand_path('../brotli-testdata', __dir__)
MANIFEST = File.expand_path('MANIFEST.tsv', __dir__)
# sha256 of c/common/dictionary.bin at COMMIT, embedded as src/mica/brotli/dictionary.bin.
DICTIONARY_SHA256 = '20e42eb1b511c21806d4d227d07e5dd06877d8ce7b3a817f378f313653f35c70'

entries = File.readlines(MANIFEST).reject { |line| line.start_with?('#') }.map { |line| line.chomp.split("\t") }
FileUtils.mkdir_p(TARGET)
Net::HTTP.start('raw.githubusercontent.com', 443, use_ssl: true) do |http|
  entries.each do |name, _bytes, sha256|
    path = File.join(TARGET, name)
    next if File.exist?(path) && Digest::SHA256.file(path).hexdigest == sha256

    response = http.request(Net::HTTP::Get.new(URI(BASE + name), 'User-Agent' => USER_AGENT))
    abort "GET #{name}: #{response.code} #{response.message}" unless response.is_a?(Net::HTTPSuccess)
    File.binwrite(path, response.body)
    actual = Digest::SHA256.file(path).hexdigest
    next if actual == sha256

    File.delete(path)
    abort "sha256 mismatch for #{name}: expected #{sha256}, got #{actual} (download deleted)"
  end
end
dictionary = File.expand_path('../../src/mica/brotli/dictionary.bin', __dir__)
unless Digest::SHA256.file(dictionary).hexdigest == DICTIONARY_SHA256
  abort 'src/mica/brotli/dictionary.bin does not match google/brotli v1.2.1 c/common/dictionary.bin'
end
puts "#{entries.size} files verified in #{TARGET}; the embedded dictionary matches its pin"
