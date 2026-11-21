#!/usr/bin/ruby
# frozen_string_literal: true

# Fetches and verifies the Inflate benchmark corpus pinned in
# bench/deflate/corpus.tsv.
#
#   /usr/bin/ruby bench/deflate/scripts/fetch_corpus.rb             # download, verify, extract, verify
#   /usr/bin/ruby bench/deflate/scripts/fetch_corpus.rb --file-rows # also print a `file` row per extracted file
#
# Each `archive` row is downloaded into bench/data/deflate/downloads/
# (git-ignored) unless a copy is already there, and its sha256 and size are
# checked against the row: a mismatch deletes the download and exits
# non-zero. A verified archive is extracted into a fresh
# bench/data/deflate/<corpus>/ directory, and every `file` row of that
# corpus is then checked (size and sha256) against the extracted file. The
# `http` rows are the snapshots committed under bench/deflate/corpus/http/;
# they are checked the same way. Any mismatch or missing file fails the
# run, so the harness never measures an input the manifest does not pin.
#
# --file-rows is the pinning aid: after an archive row changes, it prints
# the rows for its extracted files (verified archive, so the rows are a
# pure function of the pinned archive).
#
# Only the Ruby standard library is used (system /usr/bin/ruby).

require 'digest'
require 'fileutils'
require 'net/http'
require 'uri'

USER_AGENT = 'AgentC-Consulting-research/1.0 (+https://agentc.consulting; agent_c@agentc.consulting)'
DEFLATE_BENCH_DIR = File.expand_path('..', __dir__)
MANIFEST_PATH = File.join(DEFLATE_BENCH_DIR, 'corpus.tsv')
HTTP_DIR = File.join(DEFLATE_BENCH_DIR, 'corpus', 'http')
DATA_DIR = File.expand_path('../data/deflate', DEFLATE_BENCH_DIR)
DOWNLOAD_DIR = File.join(DATA_DIR, 'downloads')

ManifestRow = Struct.new(:kind, :corpus, :path, :bytes, :sha256, :source, :pinned_on, :hash_source)

def list_of_manifest_rows
  File.readlines(MANIFEST_PATH, chomp: true).reject { |line| line.empty? || line.start_with?('#') }.map do |line|
    fields = line.split("\t", -1)
    abort "#{MANIFEST_PATH}: expected 8 tab-separated fields, got #{fields.size}: #{line}" unless fields.size == 8
    row = ManifestRow.new(*fields)
    row.bytes = Integer(row.bytes)
    row
  end
end

def download(url, destination, redirects_left = 5)
  uri = URI(url)
  Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 30, read_timeout: 300) do |http|
    request = Net::HTTP::Get.new(uri)
    request['User-Agent'] = USER_AGENT
    http.request(request) do |response|
      if response.is_a?(Net::HTTPRedirection) && redirects_left.positive?
        return download(URI.join(url, response['location']).to_s, destination, redirects_left - 1)
      end
      abort "#{url}: HTTP #{response.code}" unless response.is_a?(Net::HTTPOK)

      File.open(destination, 'wb') { |file| response.read_body { |chunk| file.write(chunk) } }
    end
  end
end

# Returns nil when the file matches the row, or the reason it does not.
def mismatch_of(path, row)
  return 'the file is missing' unless File.file?(path)

  bytes = File.size(path)
  return "size #{bytes}, pinned #{row.bytes}" unless bytes == row.bytes

  sha256 = Digest::SHA256.file(path).hexdigest
  return "sha256 #{sha256}, pinned #{row.sha256}" unless sha256 == row.sha256

  nil
end

def fetch_and_verify_archive(row)
  path = File.join(DOWNLOAD_DIR, row.path)
  unless File.file?(path)
    warn "downloading #{row.source}"
    download(row.source, path)
  end
  reason = mismatch_of(path, row)
  return path unless reason

  File.delete(path) if File.exist?(path)
  abort "#{row.path} does not match bench/deflate/corpus.tsv (#{reason}); the download was deleted"
end

def extract(archive_path, directory)
  FileUtils.rm_rf(directory)
  FileUtils.mkdir_p(directory)
  command =
    if archive_path.end_with?('.tar.gz')
      ['/usr/bin/tar', '-xzf', archive_path, '-C', directory]
    elsif archive_path.end_with?('.zip')
      ['/usr/bin/unzip', '-q', archive_path, '-d', directory]
    else
      abort "#{archive_path}: only .tar.gz and .zip archives are supported"
    end
  system(*command) || abort("extracting #{archive_path} failed")
  # The archives store some files read-only; the harness only reads them.
  FileUtils.chmod_R('u+rw', directory)
end

print_file_rows = ARGV.include?('--file-rows')
FileUtils.mkdir_p(DOWNLOAD_DIR)
rows = list_of_manifest_rows
list_of_failures = []
rows.select { |row| row.kind == 'archive' }.each do |archive_row|
  archive_path = fetch_and_verify_archive(archive_row)
  directory = File.join(DATA_DIR, archive_row.corpus)
  extract(archive_path, directory)
  if print_file_rows
    Dir.children(directory).sort.each do |name|
      path = File.join(directory, name)
      next unless File.file?(path)

      puts ['file', archive_row.corpus, name, File.size(path), Digest::SHA256.file(path).hexdigest,
            archive_row.path, archive_row.pinned_on, "extracted from the verified #{archive_row.path}"].join("\t")
    end
  end
  file_rows = rows.select { |row| row.kind == 'file' && row.corpus == archive_row.corpus }
  file_rows.each do |row|
    reason = mismatch_of(File.join(directory, row.path), row)
    list_of_failures << "#{row.corpus}/#{row.path}: #{reason}" if reason
  end
  warn "#{archive_row.corpus}: #{archive_row.path} verified, #{file_rows.size} files checked"
end
http_rows = rows.select { |row| row.kind == 'http' }
http_rows.each do |row|
  reason = mismatch_of(File.join(HTTP_DIR, row.path), row)
  list_of_failures << "http/#{row.path}: #{reason}" if reason
end
warn "http: #{http_rows.size} committed bodies checked"
unless list_of_failures.empty?
  warn 'corpus verification failed:'
  list_of_failures.each { |failure| warn "  #{failure}" }
  exit 1
end
