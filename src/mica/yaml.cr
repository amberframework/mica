require "./core"

# YAML 1.2 in pure Crystal: a pull parser (`PullParser`) that reads
# events, a node API (`compose` returns the node graph, `parse` returns
# plain values under the core schema) and an emitter (`Emitter`). No
# libyaml.
#
# Every parse takes required `limits:` (`ParseLimits`: input size, depth,
# nodes, alias expansion and work) and a required `timeout:` (a
# `Time::Span`, or nil for none), and raises a typed error before the
# memory a limit guards is used, so a hostile document costs bounded
# memory and time.
#
# ```
# limits = Mica::YAML::ParseLimits::CONFIG_FILE
# config = Mica::YAML.parse(File.read("config/environments/production.yml"), limits: limits, timeout: 2.seconds)
# config["server"]["port"].as_i # => 3000
# ```
module Mica::YAML
  # Parses the first document of *source* into values under *schema*.
  # Returns a nil value when the stream holds no document.
  #
  # *merge_keys* applies `<<` merge keys (see `Resolver`), and
  # *duplicate_keys* says what a repeated mapping key does.
  def self.parse(source : String | Bytes | IO, *, limits : ParseLimits, timeout : Time::Span?,
                 dialect : Dialect = Dialect::YAML12, schema : Schema = Schema::Core, merge_keys : Bool = true,
                 duplicate_keys : DuplicateKeys = DuplicateKeys::LastWins) : Any
    parser = PullParser.new(source, limits: limits, timeout: timeout, dialect: dialect)
    root = Composer.new(parser, limits).next_document
    return Any.new(nil) unless root
    value = Resolver.new(schema, merge_keys, duplicate_keys, limits, parser.meter).resolve(root)
    parser.meter.enforce_deadline("while parsing YAML") { parser.start_position }
    value
  end

  # Parses every document of *source* into values under *schema*.
  def self.parse_all(source : String | Bytes | IO, *, limits : ParseLimits, timeout : Time::Span?,
                     dialect : Dialect = Dialect::YAML12, schema : Schema = Schema::Core, merge_keys : Bool = true,
                     duplicate_keys : DuplicateKeys = DuplicateKeys::LastWins) : Array(Any)
    parser = PullParser.new(source, limits: limits, timeout: timeout, dialect: dialect)
    composer = Composer.new(parser, limits)
    list_of_values = [] of Any
    while root = composer.next_document
      list_of_values << Resolver.new(schema, merge_keys, duplicate_keys, limits, parser.meter).resolve(root)
    end
    parser.meter.enforce_deadline("while parsing YAML") { parser.start_position }
    list_of_values
  end

  # Returns the root node of the first document of *source*, or nil when
  # the stream holds no document. Aliases are resolved to the nodes they
  # name.
  def self.compose(source : String | Bytes | IO, *, limits : ParseLimits, timeout : Time::Span?,
                   dialect : Dialect = Dialect::YAML12) : Node?
    parser = PullParser.new(source, limits: limits, timeout: timeout, dialect: dialect)
    Composer.new(parser, limits).next_document
  end

  # Returns the root node of every document of *source*.
  def self.compose_all(source : String | Bytes | IO, *, limits : ParseLimits, timeout : Time::Span?,
                       dialect : Dialect = Dialect::YAML12) : Array(Node)
    parser = PullParser.new(source, limits: limits, timeout: timeout, dialect: dialect)
    composer = Composer.new(parser, limits)
    list_of_roots = [] of Node
    while root = composer.next_document
      list_of_roots << root
    end
    list_of_roots
  end
end

require "./yaml/styles"
require "./yaml/dialect"
require "./yaml/errors"
require "./yaml/parse_limits"
require "./yaml/token"
require "./yaml/source"
require "./yaml/scanner"
require "./yaml/pull_parser"
require "./yaml/node"
require "./yaml/composer"
require "./yaml/schema"
require "./yaml/any"
require "./yaml/resolver"
require "./yaml/emit_error"
require "./yaml/emitter"
