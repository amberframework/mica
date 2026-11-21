#!/usr/bin/ruby
# frozen_string_literal: true

# Captures the real HTTP response bodies of the Inflate benchmark corpus
# into bench/deflate/corpus/http/ and prints the rows that pin them: one
# `http` row per body for bench/deflate/corpus.tsv and one row per fetched
# URL for bench/deflate/corpus/http/parts.tsv.
#
#   /usr/bin/ruby bench/deflate/scripts/capture_http_bodies.rb
#
# The committed snapshots are the corpus; this script is how they were
# made, and running it again takes a new snapshot (the sites change, so the
# hashes change with it and corpus.tsv must be updated in the same commit).
# A body made of several responses is their bytes joined in the order
# listed, with nothing between them. Only the Ruby standard library is used
# (system /usr/bin/ruby).

require 'digest'
require 'fileutils'
require 'net/http'
require 'uri'

USER_AGENT = 'AgentC-Consulting-research/1.0 (+https://agentc.consulting; agent_c@agentc.consulting)'
HTTP_DIR = File.expand_path('../corpus/http', __dir__)
SITE = 'https://agentc.consulting'
GITHUB = 'https://api.github.com'
BOOK = "#{SITE}/agent-enhanced-development"

LIST_OF_BODIES = [
  # agentc.consulting serves no HTML response near 1 KiB (its smallest page
  # is 13 KiB), so the smallest band is the IANA example page.
  ['html_1k.html', ['https://example.com/']],
  ['html_16k.html', ["#{SITE}/heatpilot"]],
  ['html_64k.html', ["#{SITE}/resources"]],
  ['html_1m.html', [
    "#{BOOK}/chapter-1/why-agents-need-conventions",
    "#{BOOK}/chapter-2/vibe-coding-as-a-squad",
    "#{BOOK}/chapter-3/naming-that-reads-like-a-sentence",
    "#{BOOK}/chapter-4/process-managers",
    "#{BOOK}/chapter-5/feature-stories",
    "#{BOOK}/chapter-6/edit-level-style",
    "#{BOOK}/chapter-7/control-flow",
    "#{BOOK}/chapter-8/how-the-workflow-runs",
    "#{BOOK}/chapter-9/adopt-it-in-ten-minutes"
  ]],
  ['json_1k.json', ["#{GITHUB}/repos/crystal-lang/crystal/tags?per_page=3"]],
  ['json_16k.json', ["#{GITHUB}/repos/amberframework/amber/issues?state=all&per_page=2"]],
  ['json_64k.json', ["#{GITHUB}/repos/crystal-lang/crystal/releases?per_page=3"]],
  ['json_1m.json', [
    "#{GITHUB}/repos/amberframework/amber/issues?state=all&per_page=100&page=1",
    "#{GITHUB}/repos/amberframework/amber/issues?state=all&per_page=100&page=2"
  ]]
].freeze

def fetch_body(url, redirects_left = 5)
  uri = URI(url)
  request = Net::HTTP::Get.new(uri)
  request['User-Agent'] = USER_AGENT
  request['Accept'] = uri.host == 'api.github.com' ? 'application/vnd.github+json' : 'text/html'
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 30, read_timeout: 120) do |http|
    http.request(request)
  end
  if response.is_a?(Net::HTTPRedirection) && redirects_left.positive?
    return fetch_body(URI.join(url, response['location']).to_s, redirects_left - 1)
  end
  abort "#{url}: HTTP #{response.code}" unless response.is_a?(Net::HTTPOK)

  response.body.b
end

FileUtils.mkdir_p(HTTP_DIR)
captured_on = Time.now.utc.strftime('%Y-%m-%d')
list_of_corpus_rows = []
list_of_part_rows = []
LIST_OF_BODIES.each do |file_name, list_of_urls|
  body = String.new(encoding: Encoding::BINARY)
  list_of_urls.each_with_index do |url, index|
    part = fetch_body(url)
    list_of_part_rows << [file_name, index + 1, part.bytesize, Digest::SHA256.hexdigest(part), captured_on, url]
    body << part
  end
  File.binwrite(File.join(HTTP_DIR, file_name), body)
  source = list_of_urls.size == 1 ? list_of_urls.first : "#{list_of_urls.size} responses joined, see corpus/http/parts.tsv"
  list_of_corpus_rows << ['http', 'http', file_name, body.bytesize, Digest::SHA256.hexdigest(body), source, captured_on,
                          'sha256 of the body as captured']
end
puts '# rows for bench/deflate/corpus.tsv'
list_of_corpus_rows.each { |row| puts row.join("\t") }
puts '# rows for bench/deflate/corpus/http/parts.tsv'
list_of_part_rows.each { |row| puts row.join("\t") }
