# Builds the Brotli benchmark corpus under DIR: the Canterbury corpus
# (cantrbry.tar.gz, sha256 pinned in bench/deflate/corpus.tsv) and the
# HTTP bodies of bench/deflate/corpus/http, each verified by sha256 and
# compressed by the reference `brotli` CLI at quality 5 and 11, window 22.
#
#   /usr/bin/ruby bench/brotli/prepare_corpus.rb DIR BROTLI_CLI
require "digest"
require "fileutils"

dir, cli = ARGV.fetch(0), ARGV.fetch(1)
root = File.expand_path("../..", __dir__)
rows = File.readlines(File.join(root, "bench/deflate/corpus.tsv")).reject { |l| l.start_with?("#") }.map { |l| l.chomp.split("\t") }
FileUtils.mkdir_p(File.join(dir, "plain"))
archive = rows.find { |r| r[0] == "archive" && r[1] == "canterbury" }
tarball = File.join(dir, "cantrbry.tar.gz")
system("curl", "-sSfL", "-o", tarball, archive[5], exception: true) unless File.exist?(tarball)
abort "cantrbry.tar.gz sha256 mismatch" unless Digest::SHA256.file(tarball).hexdigest == archive[4]
system("tar", "xzf", tarball, "-C", File.join(dir, "plain"), exception: true)
cases = []
rows.each do |kind, corpus, path, bytes, sha|
  next unless (kind == "file" && corpus == "canterbury") || kind == "http"
  source = kind == "http" ? File.join(root, "bench/deflate/corpus/http", path) : File.join(dir, "plain", path)
  next unless File.exist?(source)
  abort "#{path} sha256 mismatch" unless Digest::SHA256.file(source).hexdigest == sha
  name = "#{corpus}-#{path}"
  FileUtils.cp(source, File.join(dir, "plain", name))
  [5, 11].each do |quality|
    target = File.join(dir, "#{name}.q#{quality}.br")
    system(cli, "-f", "-q", quality.to_s, "-w", "22", "-o", target, source, exception: true)
    cases << [name, quality, File.size(source), File.size(target)]
  end
end
File.write(File.join(dir, "cases.tsv"), cases.map { |c| c.join("\t") }.join("\n") + "\n")
puts "#{cases.size} cases in #{dir}"
