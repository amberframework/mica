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
require "./write_the_source"

source = ARGV[0]? || abort("usage: emit_static_pattern SOURCE OPTIONS")
options = Mica::Regex::CompileOptions.new((ARGV[1]? || "0").to_u32)
result = Mica::Regex::Static::BuildTheTables.new(source, options).perform
Mica::Regex::Static::WriteTheSource.new(result, STDOUT).perform
