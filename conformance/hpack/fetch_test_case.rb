#!/usr/bin/ruby
# frozen_string_literal: true

# Fetches the HPACK interoperability corpus
# (https://github.com/http2jp/hpack-test-case) at a pinned commit and
# verifies the archive.
#
#   /usr/bin/ruby conformance/hpack/fetch_test_case.rb
#
# The archive is downloaded into conformance/hpack-test-case/ (git-ignored)
# unless a verified copy is already there. Its sha256 is checked against
# ARCHIVE_SHA256: a mismatch deletes the download and exits non-zero. A
# verified archive is extracted into conformance/hpack-test-case/data/.
# spec/hpack/test_case_spec.cr checks the sha256 again before it reads the
# stories. spec/vectors/hpack/SOURCES.md records the pin.
#
# To move the pin, change COMMIT and ARCHIVE_SHA256 here and in
# spec/hpack/test_case_spec.cr together.
#
# Only the Ruby standard library is used (system /usr/bin/ruby).

require 'digest'
require 'fileutils'
require 'net/http'
require 'uri'

COMMIT = '8a1406e7d14bfcb6c046021f13cc15cfb162726d'
ARCHIVE_SHA256 = '53355bf708fb890a235b3a679061d116a020818e92caaadbc243f9c91c4c48eb'
URL = "https://codeload.github.com/http2jp/hpack-test-case/tar.gz/#{COMMIT}"
USER_AGENT = 'AgentC-Consulting-research/1.0 (+https://agentc.consulting; agent_c@agentc.consulting)'
TARGET = File.expand_path('../hpack-test-case', __dir__)
ARCHIVE = File.join(TARGET, "hpack-test-case-#{COMMIT}.tar.gz")
DATA = File.join(TARGET, 'data')

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

FileUtils.mkdir_p(TARGET)
download(URL, ARCHIVE) unless File.exist?(ARCHIVE)
actual = Digest::SHA256.file(ARCHIVE).hexdigest
unless actual == ARCHIVE_SHA256
  File.delete(ARCHIVE)
  abort "sha256 mismatch for #{URL}: expected #{ARCHIVE_SHA256}, got #{actual} (download deleted)"
end
FileUtils.rm_rf(DATA)
FileUtils.mkdir_p(DATA)
system('tar', 'xzf', ARCHIVE, '-C', DATA, '--strip-components', '1') || abort('tar failed')
puts "hpack-test-case #{COMMIT} (sha256 #{ARCHIVE_SHA256}) in #{DATA}"
