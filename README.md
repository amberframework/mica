# Mica

A pure-Crystal XML 1.0 (5th edition) and Namespaces 1.0 library for the
Amber ecosystem: a streaming reader, a DOM, a builder and XPath 1.0. It has
no C dependencies (no libxml2), never reads the network or file system while
parsing, and is secure by default.

The module is `Mica`, so it coexists with stdlib `XML`. The API follows
stdlib `XML` closely; porting is mostly renaming the constant.

## Installation

```yaml
dependencies:
  mica:
    github: ORG/mica # repository location pending
    version: 0.1.0
```

```crystal
require "mica"
```

## Parsing into a document

```crystal
document = Mica.parse(File.read("feed.xml")) # String, Bytes or IO
feed = document.root.not_nil!                  # Mica::Node
feed.name                                      # local name, like stdlib
feed["version"]?                               # attribute or nil
feed.children.select(&.element?)
document.xpath_nodes("//item/title").map(&.content)
```

`Mica::Node` is a small struct (document + index); nodes live in an arena
owned by `Mica::Document`. It supports the stdlib `XML::Node` API: `[]`,
`[]?`, `[]=`, `delete`, `attributes`, `children`, `content`/`text`/
`inner_text`, `content=`, `name`, `name=`, `namespace`, `namespaces`,
`namespace_definitions`, `namespace_scopes`, `parent`, `next`/`previous`
(and `_sibling`/`_element` forms), `first_element_child`, `root`, `type` and
the type predicates, `unlink`, `to_s`, `to_xml(indent:, indent_text:)`, and
the XPath methods. Extras: `qualified_name`, `prefix`, `namespace_uri`.

## Streaming with the reader

```crystal
File.open("s3-listing.xml") do |file|
  reader = Mica::Reader.new(file)
  while reader.read
    if reader.node_type.element? && reader.local_name == "Key"
      reader.read
      puts reader.value
    end
  end
end
```

The reader keeps one buffer holding the current token, so memory stays flat
(about 4 MB peak RSS on a 50 MB file). Methods: `read`, `node_type`, `name`,
`local_name`, `prefix`, `namespace_uri`, `value`, `depth`,
`empty_element?`, `has_attributes?`, `attributes_count`,
`move_to_first_attribute`, `move_to_next_attribute`, `move_to_attribute`,
`move_to_element`, `[]`, `[]?`, `next`, `next_sibling`, `expand`,
`read_inner_xml`, `read_outer_xml`, `line_number`, `column_number`.

## Building XML

```crystal
xml = Mica.build(indent: 2) do |builder|
  builder.element("ListBucketResult", xmlns: "http://s3.amazonaws.com/doc/2006-03-01/") do
    builder.element("Key") { builder.text "photos/a&b.jpg" }
  end
end
```

The builder escapes text and attribute values, checks names and
characters, splits `]]>` in CDATA, and raises `Mica::BuilderError` for
misuse (an attribute after content, a second root, a `--` in a comment).
Methods match stdlib `XML::Builder`; it writes UTF-8 only.

## Security and limits

Every parse is secure by default:

- External DTD subsets and external entities (general and parameter) are
  never fetched. A reference to an external parsed entity in content is
  reported as an `ENTITY_REFERENCE` node and kept as `&name;` on output.
- Entity expansion is bounded by count and by total bytes (DTD attribute
  defaults are charged to the same budget); entity nesting and element
  nesting are bounded; recursion is a well-formedness error.
- Token size, name length, attributes per element and total input size
  are bounded. The parser is iterative, as are the serializer and the
  XPath axes, so deep documents cannot overflow the stack.

```crystal
options = Mica::ParserOptions.new(
  namespace_aware: true,
  max_entity_expansions: 10_000,               # default
  max_entity_expansion_bytes: 16 * 1024 * 1024, # default
  max_entity_depth: 16,                        # default
  max_element_depth: 1024,                     # default
  max_name_bytes: 50_000,                      # default
  max_attributes: 10_000,                      # default
  max_token_bytes: 10 * 1024 * 1024,           # default
  max_input_bytes: nil,                        # default: no cap
)
Mica.parse(body, options)
```

Limit violations raise `Mica::LimitExceededError`.

## Errors

All errors inherit from `Mica::Error`:

| Error | Raised for |
|---|---|
| `Mica::ParseError` | well-formedness or namespace errors; has `line_number` and `column_number` (characters) |
| `Mica::LimitExceededError` | a `ParserOptions` limit (subclass of `ParseError`) |
| `Mica::EncodingError` | unsupported encodings, invalid UTF-8/UTF-16 (subclass of `ParseError`) |
| `Mica::XPathError` | XPath syntax errors and unsupported XPath features |
| `Mica::BuilderError` | builder misuse |

## Encodings

UTF-8 (with or without a byte order mark) and UTF-16 (big or little endian,
byte order mark required) are decoded in Crystal. The XML declaration's
encoding must name UTF-8 or UTF-16; `US-ASCII` is accepted and enforced.
Any other declared encoding raises `Mica::EncodingError` naming it.

## Differences from stdlib `XML`

- Parsing is strict: the first error raises (stdlib's default options
  recover from errors and collect them).
- `Reader#expand`, `read_inner_xml` and `read_outer_xml` consume the
  element's subtree: afterwards the reader sits on the element's end.
- `Node` is a struct; nodes from one document compare equal by position.
- `xpath_string`, `xpath_float` and `xpath_bool` convert any result type
  with the XPath conversion rules instead of requiring that type.
- No HTML parser.

## XPath

`Node#xpath`, `xpath_nodes`, `xpath_node`, `xpath_string`, `xpath_float`,
`xpath_bool` take an optional prefix map. Without one, the namespaces
declared on the root element are registered (the default namespace under
the prefix `xmlns`), as in stdlib. `Mica::XPath.compile(path)` returns a
reusable expression.

```crystal
s3 = {"s3" => "http://s3.amazonaws.com/doc/2006-03-01/"}
document.xpath_nodes("//s3:Contents[s3:Size > 1024]/s3:Key", s3)
document.xpath_string("string(//s3:NextContinuationToken)", s3)
document.xpath_float("count(//s3:Contents)", s3)
```

Supported grammar (XPath 1.0, section numbers from the recommendation):

```
Expr            ::= OrExpr
OrExpr          ::= AndExpr ('or' AndExpr)*
AndExpr         ::= EqualityExpr ('and' EqualityExpr)*
EqualityExpr    ::= RelationalExpr (('=' | '!=') RelationalExpr)*
RelationalExpr  ::= AdditiveExpr (('<' | '>' | '<=' | '>=') AdditiveExpr)*
AdditiveExpr    ::= MultiplicativeExpr (('+' | '-') MultiplicativeExpr)*
MultiplicativeExpr ::= UnaryExpr (('*' | 'div' | 'mod') UnaryExpr)*
UnaryExpr       ::= UnionExpr | '-' UnaryExpr
UnionExpr       ::= PathExpr ('|' PathExpr)*
PathExpr        ::= LocationPath | FilterExpr (('/' | '//') RelativeLocationPath)?
FilterExpr      ::= PrimaryExpr Predicate*
PrimaryExpr     ::= '$' QName | '(' Expr ')' | Literal | Number | FunctionCall
LocationPath    ::= '/' RelativeLocationPath? | '//' RelativeLocationPath | RelativeLocationPath
RelativeLocationPath ::= Step (('/' | '//') Step)*
Step            ::= AxisSpecifier NodeTest Predicate* | '.' | '..'
AxisSpecifier   ::= AxisName '::' | '@'?
NodeTest        ::= '*' | NCName ':*' | QName
                  | 'node()' | 'text()' | 'comment()' | 'processing-instruction(' Literal? ')'
Predicate       ::= '[' Expr ']'
```

- Axes: `child`, `descendant`, `descendant-or-self`, `self`, `parent`,
  `ancestor`, `ancestor-or-self`, `following`, `following-sibling`,
  `preceding`, `preceding-sibling`, `attribute`. Not supported:
  `namespace`.
- Functions: `last`, `position`, `count`, `local-name`, `namespace-uri`,
  `name`, `string`, `concat`, `starts-with`, `contains`,
  `substring-before`, `substring-after`, `substring`, `string-length`,
  `normalize-space`, `translate`, `not`, `true`, `false`, `boolean`,
  `number`, `sum`, `floor`, `ceiling`, `round`. Not supported: `id`,
  `lang`.
- Unprefixed names match only elements in no namespace (XPath 1.0 rule);
  use a prefix map for namespaced documents.
- Unsupported features and unknown functions raise `Mica::XPathError`.

## Development

```sh
shards-alpha install --frozen
crystal-alpha spec                      # includes 20,000 seeded fuzz cases
crystal-alpha tool format --check
bin/ameba src spec                      # build: crystal-alpha build lib/ameba/bin/ameba.cr -o bin/ameba

# W3C XML Conformance Test Suite (xmlconf 2013-09-23,
# sha256 9b61db9f5dbffa545f4b8d78422167083a8568c59bd1129f94138f936cf6fc1f)
crystal-alpha run --release conformance/run.cr -- /path/to/xmlconf
crystal-alpha run --release conformance/run_libxml2.cr -- /path/to/xmlconf   # baseline

# Larger fuzz campaigns and the libxml2 differential
MICA_FUZZ_SEED=7 MICA_FUZZ_ITERATIONS=300000 crystal-alpha spec spec/mica/fuzz_spec.cr
crystal-alpha run --release fuzz/differential.cr -- 20261024 20000

# Benchmarks against stdlib XML (libxml2)
crystal-alpha run --release bench/generate.cr
bench/run.sh
```

The libxml2 comparison programs (`conformance/run_libxml2.cr`,
`bench/bench_stdlib.cr`, `fuzz/differential.cr`) are the only code that
requires stdlib `xml`; the library and its specs never link libxml2.

## License

MIT
