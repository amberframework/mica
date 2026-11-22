#!/usr/bin/ruby
# frozen_string_literal: true

# Fetches and verifies the YAML benchmark corpus pinned in
# bench/yaml/corpus.tsv.
#
#   /usr/bin/ruby bench/yaml/scripts/fetch_corpus.rb         # download and verify
#   /usr/bin/ruby bench/yaml/scripts/fetch_corpus.rb --pin   # print rows with the size and sha256 of what was downloaded
#
# Each `url` row names a file at a pinned commit of a public repository.
# It is downloaded into bench/data/yaml/<corpus>/ (git-ignored) unless a
# copy is already there, and its size and sha256 are checked against the
# row: a mismatch deletes the download and exits non-zero. The `file`
# rows are snapshots committed under bench/yaml/corpus/; they are checked
# the same way. The harness never measures an input the manifest does not
# pin.
#
# --pin is the pinning aid for a new or changed row: it prints every row
# with the measured size and sha256, to paste back after review.
#
# Only the Ruby standard library is used (system /usr/bin/ruby).

require 'digest'
require 'fileutils'
require 'net/http'
require 'uri'

USER_AGENT = 'AgentC-Consulting-research/1.0 (+https://agentc.consulting; agent_c@agentc.consulting)'
BENCH_DIR = File.expand_path('..', __dir__)
MANIFEST_PATH = File.join(BENCH_DIR, 'corpus.tsv')
DATA_DIR = File.expand_path('../data/yaml', BENCH_DIR)

Row = Struct.new(:kind, :corpus, :name, :bytes, :sha256, :source)

def list_of_rows
  File.readlines(MANIFEST_PATH, chomp: true).reject { |line| line.empty? || line.start_with?('#') }.map do |line|
    fields = line.split("\t", -1)
    abort "#{MANIFEST_PATH}: expected 6 tab-separated fields, got #{fields.size}: #{line}" unless fields.size == 6
    Row.new(*fields)
  end
end

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

def path_of(row)
  return File.join(BENCH_DIR, 'corpus', row.corpus, row.name) if row.kind == 'file'

  File.join(DATA_DIR, row.corpus, row.name)
end

pin = ARGV.include?('--pin')
status = 0
list_of_rows.each do |row|
  path = path_of(row)
  if row.kind == 'url' && !File.exist?(path)
    FileUtils.mkdir_p(File.dirname(path))
    download(row.source, path)
  end
  abort "#{path} is missing" unless File.exist?(path)
  bytes = File.size(path)
  sha256 = Digest::SHA256.file(path).hexdigest
  if pin
    puts [row.kind, row.corpus, row.name, bytes, sha256, row.source].join("\t")
  elsif bytes != Integer(row.bytes) || sha256 != row.sha256
    warn "MISMATCH #{row.corpus}/#{row.name}: expected #{row.bytes} bytes sha256 #{row.sha256}, got #{bytes} bytes sha256 #{sha256}"
    File.delete(path) if row.kind == 'url'
    status = 1
  end
end
puts "corpus verified: #{list_of_rows.size} files" if status.zero? && !pin
exit status
