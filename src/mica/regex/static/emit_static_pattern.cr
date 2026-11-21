# The build-time program behind `Mica::Regex.static`: the compiler runs it
# (through the `run` macro) once per static pattern while the application
# builds, and pastes its output into the application's source.
#
#   emit_static_pattern SOURCE OPTIONS
#
# SOURCE is the pattern text and OPTIONS the `CompileOptions` value. It
# prints the kind of result, a compile-time note, the line `%%`, then the
# Crystal expression for the pattern (see
# `Mica::Regex::Static::WriteTheSource`).
#
# With MICA_STATIC_DECODER_COLUMNS=always in the environment of the build,
# every table is read over UTF-8 decoder states
# (`Mica::Regex::Static::BuildTheDecoderProduct`), which the static
# differential uses to cover that layout with every pattern.
require "./write_the_source"

source = ARGV[0]? || abort("usage: emit_static_pattern SOURCE OPTIONS")
options = Mica::Regex::CompileOptions.new((ARGV[1]? || "0").to_u32)
always_decoder_columns = ENV["MICA_STATIC_DECODER_COLUMNS"]? == "always"
result = Mica::Regex::Static::BuildTheTables.new(source, options, always_decoder_columns).perform
Mica::Regex::Static::WriteTheSource.new(result, STDOUT).perform
