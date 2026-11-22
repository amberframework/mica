# The smallest useful Mica YAML program: read a configuration document
# with the pull parser and the node API, then write one with the emitter.
# Its dynamic libraries and symbols are what any user of Mica::YAML links
# (see scripts/check_linkage.sh), and they include no libyaml.
require "../../src/mica/core"
require "../../src/mica/yaml"

SOURCE = <<-YAML
  defaults: &defaults
    host: localhost
    port: 3000
  development:
    <<: *defaults
    secrets: [a, "b"]
  YAML

limits = Mica::YAML::ParseLimits::CONFIG_FILE
input = ARGV[0]?.try { |path| File.read(path) } || SOURCE
events = 0
parser = Mica::YAML::PullParser.new(input, limits: limits, timeout: 2.seconds)
until parser.kind.stream_end?
  events += 1
  parser.read_next
end
list_of_documents = Mica::YAML.parse_all(input, limits: limits, timeout: 2.seconds)
STDOUT << "events=" << events << " documents=" << list_of_documents.size << '\n'
STDOUT << "port=" << list_of_documents.first["development"]["port"].as_i << '\n' unless ARGV[0]?

emitter = Mica::YAML::Emitter.new(STDOUT)
emitter.stream_start
emitter.document_start
emitter.mapping_start
emitter.scalar("written by")
emitter.scalar("Mica::YAML::Emitter")
emitter.mapping_end
emitter.document_end
emitter.stream_end
emitter.flush
