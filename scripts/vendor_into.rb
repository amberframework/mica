#!/usr/bin/ruby
# frozen_string_literal: true

# Places a pinned copy of one Mica component inside another library, for a
# library that cannot name the Mica shard as a dependency.
#
#   /usr/bin/ruby scripts/vendor_into.rb --commit COMMIT --component deflate --namespace Amber --destination ../amber/src/amber/vendor
#   /usr/bin/ruby scripts/vendor_into.rb --check --destination ../amber/src/amber/vendor
#
# The copy is taken from one commit of this repository with `git archive`,
# so the working tree and any uncommitted edit play no part. Every constant
# moves under the namespace given (`Mica::Gzip` becomes `Amber::Mica::Gzip`),
# so that two libraries which each carry a copy, and an application that
# uses the Mica shard itself, can be compiled into one program, at different
# versions if need be.
#
# Components:
#
#   deflate      Mica::Deflate, Mica::Zlib and Mica::Gzip (decoders and
#                encoders) with Mica::Core. The library requires
#                "<destination>/mica/deflate".
#   compression  deflate plus Mica::Brotli. The library requires
#                "<destination>/mica/deflate" and "<destination>/mica/brotli".
#   decimal      Mica::Decimal128, Mica::Currency and Mica::Money, with no
#                Mica::Core. The library requires "<destination>/mica/decimal",
#                and for the opt-in conversions "<destination>/mica/decimal/json",
#                "<destination>/mica/decimal/yaml" or "<destination>/mica/decimal/big".
#
# The destination receives:
#
#   mica/**                   the source, under the new namespace
#   MICA_LICENSE              the license
#   MICA_VENDORED.json        the commit, the component, the namespace and
#                             each file sha256
#
# `--check` recomputes every sha256 in the manifest and exits 1 on the first
# file that is missing, extra or different. The same check belongs in the
# spec suite of the library that carries the copy.

require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "rubygems/package"
require "stringio"

REPOSITORY_ROOT = File.expand_path("..", __dir__)
MANIFEST_NAME = "MICA_VENDORED.json"
LICENSE_NAME = "MICA_LICENSE"
SOURCE_REPOSITORY = "https://github.com/amberframework/mica"
NAMESPACE_PATTERN = /\A[A-Z][A-Za-z0-9]*(::[A-Z][A-Za-z0-9]*)*\z/.freeze

def fail_with(message)
  warn "vendor_into: #{message}"
  exit 1
end

def run_git(*arguments)
  output, status = Open3.capture2("git", "-C", REPOSITORY_ROOT, *arguments)
  fail_with("git #{arguments.join(" ")} failed") unless status.success?
  output
end

# The paths each component takes from `src/mica`.
LIST_OF_PATHS_BY_COMPONENT = {
  "deflate"     => ["src/mica/core.cr", "src/mica/core", "src/mica/deflate.cr", "src/mica/deflate", "src/mica/zlib.cr",
                    "src/mica/gzip.cr"],
  "compression" => ["src/mica/core.cr", "src/mica/core", "src/mica/deflate.cr", "src/mica/deflate", "src/mica/zlib.cr",
                    "src/mica/gzip.cr", "src/mica/brotli.cr", "src/mica/brotli"],
  "decimal"     => ["src/mica/decimal.cr", "src/mica/decimal"],
}.freeze

# The files a library requires for each component; each must exist at the
# commit taken.
LIST_OF_ENTRY_FILES_BY_COMPONENT = {
  "deflate"     => ["src/mica/deflate.cr"],
  "compression" => ["src/mica/deflate.cr", "src/mica/brotli.cr"],
  "decimal"     => ["src/mica/decimal.cr"],
}.freeze

# Returns {path => contents} for the files of *component* and LICENSE at
# *commit*, read from the tar stream of `git archive`.
def files_at(commit, component)
  archive = run_git("archive", "--format=tar", commit, *LIST_OF_PATHS_BY_COMPONENT.fetch(component), "LICENSE")
  files = {}
  Gem::Package::TarReader.new(StringIO.new(archive)) do |tar|
    tar.each { |entry| files[entry.full_name] = entry.read if entry.file? }
  end
  files
end

# Moves every constant of the source under *namespace*.
def under_namespace(source, namespace)
  source
    .gsub(/^module Mica$/, "module #{namespace}::Mica")
    .gsub(/(?<![\w:])Mica::/, "#{namespace}::Mica::")
end

def sha256_of(bytes)
  Digest::SHA256.hexdigest(bytes)
end

def vendor(commit, component, namespace, destination)
  full_commit = run_git("rev-parse", "--verify", "#{commit}^{commit}").strip
  files = files_at(full_commit, component)
  LIST_OF_ENTRY_FILES_BY_COMPONENT.fetch(component).each do |entry_file|
    fail_with("commit #{full_commit} holds no #{entry_file}") unless files.key?(entry_file)
  end

  FileUtils.rm_rf(File.join(destination, "mica"))
  FileUtils.rm_f([File.join(destination, MANIFEST_NAME), File.join(destination, LICENSE_NAME)])
  FileUtils.mkdir_p(destination)

  list_of_files = []
  files.sort.each do |path, contents|
    if path == "LICENSE"
      relative_path = LICENSE_NAME
      written = contents
    else
      relative_path = path.delete_prefix("src/")
      # Data files (the Brotli dictionary) are copied byte for byte.
      written = path.end_with?(".cr") ? under_namespace(contents, namespace) : contents
    end
    target = File.join(destination, relative_path)
    FileUtils.mkdir_p(File.dirname(target))
    File.binwrite(target, written)
    list_of_files << { "path" => relative_path, "sha256" => sha256_of(written), "source_sha256" => sha256_of(contents) }
  end

  manifest = {
    "source" => SOURCE_REPOSITORY,
    "commit" => full_commit,
    "component" => component,
    "namespace" => "#{namespace}::Mica",
    "made_by" => "scripts/vendor_into.rb",
    "note" => "A pinned copy. Change Mica in its own repository, then run the script again; edits made here fail the check.",
    "list_of_files" => list_of_files,
  }
  File.write(File.join(destination, MANIFEST_NAME), JSON.pretty_generate(manifest) + "\n")
  puts "vendored #{list_of_files.size} files (#{component}) from #{full_commit} into #{destination} as #{namespace}::Mica"
end

def check(destination)
  manifest_path = File.join(destination, MANIFEST_NAME)
  fail_with("#{manifest_path} is missing") unless File.file?(manifest_path)

  manifest = JSON.parse(File.read(manifest_path))
  list_of_paths = manifest.fetch("list_of_files").map { |entry| entry.fetch("path") }
  manifest.fetch("list_of_files").each do |entry|
    target = File.join(destination, entry.fetch("path"))
    fail_with("#{target} is missing") unless File.file?(target)
    observed = sha256_of(File.binread(target))
    next if observed == entry.fetch("sha256")

    fail_with("#{target} does not match its pin: sha256 is #{observed}, the manifest pins #{entry.fetch("sha256")}")
  end

  list_of_present = Dir.glob("mica/**/*", base: destination).select { |path| File.file?(File.join(destination, path)) }
  list_of_extra = list_of_present - list_of_paths
  fail_with("files with no pin: #{list_of_extra.join(", ")}") unless list_of_extra.empty?

  puts "#{list_of_paths.size} files match #{manifest.fetch("commit")} (#{manifest.fetch("namespace")}, #{manifest.fetch("component")})"
end

options = {}
OptionParser.new do |parser|
  parser.on("--commit COMMIT") { |value| options[:commit] = value }
  parser.on("--component COMPONENT") { |value| options[:component] = value }
  parser.on("--namespace NAMESPACE") { |value| options[:namespace] = value }
  parser.on("--destination DIRECTORY") { |value| options[:destination] = value }
  parser.on("--check") { options[:check] = true }
end.parse!

destination = options[:destination] || fail_with("--destination is required")
destination = File.expand_path(destination)

if options[:check]
  check(destination)
else
  commit = options[:commit] || fail_with("--commit is required: the copy is pinned to one commit")
  component = options[:component] || fail_with("--component is required: one of #{LIST_OF_PATHS_BY_COMPONENT.keys.join(", ")}")
  fail_with("#{component} is not a component: use one of #{LIST_OF_PATHS_BY_COMPONENT.keys.join(", ")}") unless LIST_OF_PATHS_BY_COMPONENT.key?(component)
  namespace = options[:namespace] || fail_with("--namespace is required")
  fail_with("#{namespace} is not a constant path such as Amber or Amber::Support") unless namespace.match?(NAMESPACE_PATTERN)
  vendor(commit, component, namespace, destination)
end
