#!/usr/bin/ruby
# frozen_string_literal: true

# Fetches the official YAML test suite (https://github.com/yaml/yaml-test-suite)
# at a pinned commit of its data branch and verifies the archive.
#
#   /usr/bin/ruby conformance/yaml/fetch_suite.rb
#
# The archive is downloaded into conformance/yaml-test-suite/ (git-ignored)
# unless a verified copy is already there. Its sha256 is checked against
# SUITE_SHA256: a mismatch deletes the download and exits non-zero. A
# verified archive is extracted into conformance/yaml-test-suite/data/.
#
# The pin is the commit the tag data-2022-01-17 points to (the suite's
# latest data release). To move it, change SUITE_COMMIT and SUITE_SHA256
# together.
#
# Only the Ruby standard library is used (system /usr/bin/ruby).

require 'digest'
require 'fileutils'
require 'net/http'
require 'uri'

SUITE_TAG = 'data-2022-01-17'
SUITE_COMMIT = '6e6c296ae9c9d2d5c4134b4b64d01b29ac19ff6f'
SUITE_SHA256 = 'cc4a08f9ccc1cb2e66f32b3f1192bf1f07b3175682bbb715bf709bafa70322d4'
SUITE_URL = "https://codeload.github.com/yaml/yaml-test-suite/tar.gz/#{SUITE_COMMIT}"
USER_AGENT = 'AgentC-Consulting-research/1.0 (+https://agentc.consulting; agent_c@agentc.consulting)'
TARGET = File.expand_path('../yaml-test-suite', __dir__)
ARCHIVE = File.join(TARGET, "yaml-test-suite-#{SUITE_COMMIT}.tar.gz")
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
download(SUITE_URL, ARCHIVE) unless File.exist?(ARCHIVE)
actual = Digest::SHA256.file(ARCHIVE).hexdigest
unless actual == SUITE_SHA256
  File.delete(ARCHIVE)
  abort "sha256 mismatch for #{SUITE_URL}: expected #{SUITE_SHA256}, got #{actual} (download deleted)"
end
FileUtils.rm_rf(DATA)
FileUtils.mkdir_p(DATA)
system('tar', 'xzf', ARCHIVE, '-C', DATA, '--strip-components', '1') || abort('tar failed')
puts "yaml-test-suite #{SUITE_TAG} (#{SUITE_COMMIT}, sha256 #{SUITE_SHA256}) in #{DATA}"
