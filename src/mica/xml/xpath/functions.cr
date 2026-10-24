module Mica::XML::XPath
  # :nodoc:
  #
  # The supported core function library and its arities.
  module Functions
    # name => {minimum arguments, maximum arguments (-1 for unbounded)}
    SIGNATURES = {
      "last"             => {0, 0},
      "position"         => {0, 0},
      "count"            => {1, 1},
      "local-name"       => {0, 1},
      "namespace-uri"    => {0, 1},
      "name"             => {0, 1},
      "string"           => {0, 1},
      "concat"           => {2, -1},
      "starts-with"      => {2, 2},
      "contains"         => {2, 2},
      "substring-before" => {2, 2},
      "substring-after"  => {2, 2},
      "substring"        => {2, 3},
      "string-length"    => {0, 1},
      "normalize-space"  => {0, 1},
      "translate"        => {3, 3},
      "not"              => {1, 1},
      "true"             => {0, 0},
      "false"            => {0, 0},
      "boolean"          => {1, 1},
      "number"           => {0, 1},
      "sum"              => {1, 1},
      "floor"            => {1, 1},
      "ceiling"          => {1, 1},
      "round"            => {1, 1},
    }

    UNSUPPORTED = {"id", "lang"}

    def self.check_signature(name : String, count : Int32, source : String) : Nil
      if UNSUPPORTED.includes?(name)
        raise XPathError.new("The XPath function #{name}() is not supported in XPath #{source.inspect}")
      end
      signature = SIGNATURES[name]?
      raise XPathError.new("Unknown XPath function #{name}() in XPath #{source.inspect}") unless signature
      minimum, maximum = signature
      if count < minimum || (maximum >= 0 && count > maximum)
        raise XPathError.new("Wrong number of arguments (#{count}) for #{name}() in XPath #{source.inspect}")
      end
    end
  end
end
