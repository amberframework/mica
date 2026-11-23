#!/usr/bin/ruby
# frozen_string_literal: true

# Fetches the Encoding Standard's index files and the web-platform-tests
# `encoding/` files Mica's encoding conformance runs use, each at a pinned
# commit, and verifies every file's sha256.
#
#   /usr/bin/ruby conformance/encoding/fetch_vectors.rb
#
# Files land in conformance/encoding-vectors/whatwg/ and
# conformance/encoding-vectors/wpt/ (git-ignored). A file already present is
# re-verified, not downloaded again. A sha256 mismatch deletes the file and
# exits non-zero, naming it. The specs and scripts/generate_encoding_tables.rb
# verify the same hashes again before they read a file (all three read conformance/encoding/MANIFEST).
#
# To move a pin, change the commit, run this script with MICA_REPIN=1 (it then
# prints the new hashes instead of failing), and paste them below.
#
# Only the Ruby standard library is used (system /usr/bin/ruby).

require 'digest'
require 'fileutils'
require 'net/http'
require 'uri'

# whatwg/encoding "Reset TextDecoder when decode() throws" (2026-11-20).
WHATWG_COMMIT = '7d2e3e08e11f57ba1b080390b490d53648c6f69c'
# web-platform-tests: the latest commit touching encoding/ on 2026-11-22.
WPT_COMMIT = 'f0045110fe5cd9736dbd4dee58ede80b0a753ef3'
USER_AGENT = 'AgentC-Consulting-research/1.0 (+https://agentc.consulting; agent_c@agentc.consulting)'
TARGET = File.expand_path('../encoding-vectors', __dir__)

SOURCES = {
  'whatwg' => "https://raw.githubusercontent.com/whatwg/encoding/#{WHATWG_COMMIT}/",
  'wpt' => "https://raw.githubusercontent.com/web-platform-tests/wpt/#{WPT_COMMIT}/encoding/"
}.freeze

# One line per file: source, path, sha256. The table generator and the specs
# read the same list.
FILES = File.readlines(File.join(__dir__, "MANIFEST"), chomp: true).reject { |line| line.empty? || line.start_with?("#") }.map(&:split).freeze

def download(url, destination, redirects_left = 5)
  uri = URI(url)
  Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
    http.request(Net::HTTP::Get.new(uri, 'User-Agent' => USER_AGENT)) do |response|
      case response
      when Net::HTTPSuccess
        File.open(destination, 'wb') { |file| response.read_body { |chunk| file.write(chunk) } }
      when Net::HTTPRedirection
        abort "too many redirects for #{url}" if redirects_left.zero?
        return download(response['location'], destination, redirects_left - 1)
      else
        abort "GET #{url}: #{response.code} #{response.message}"
      end
    end
  end
end

repin = ENV['MICA_REPIN'] == '1'
FILES.each do |source, path, sha256|
  destination = File.join(TARGET, source, path)
  FileUtils.mkdir_p(File.dirname(destination))
  download(SOURCES.fetch(source) + path, destination) unless File.exist?(destination)
  actual = Digest::SHA256.file(destination).hexdigest
  next if actual == sha256

  if repin
    puts "#{source} #{path} #{actual}"
  else
    File.delete(destination)
    abort "sha256 mismatch for #{source}/#{path}: expected #{sha256}, got #{actual} (file deleted)"
  end
end
puts "#{FILES.size} encoding vector files verified in #{TARGET} (WHATWG #{WHATWG_COMMIT}, WPT #{WPT_COMMIT})"
