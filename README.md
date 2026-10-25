# Mica

A pure-Crystal parsing library for the Amber ecosystem. Mica is a family of
format parsers on one shared core:

- `Mica::Core`: input with positions (bytes or streams), strict UTF-8, the
  UTF-16/UTF-32/ISO-8859-1 transcoder, encodings, limits, the work budget
  and deadline, and the error types every format raises.
- `Mica::XML`: XML 1.0 (5th edition) and XML 1.1 (2nd edition) with
  Namespaces 1.0 and 1.1: a streaming reader, a DOM, a builder and
  XPath 1.0.
- `Mica::Form`: `application/x-www-form-urlencoded` bodies and query
  strings (WHATWG URL Standard, section 5) into ordered pairs, and bracket
  and dot keys (`user[address][city]`, `tags[]`, `user.name`) into a
  nested value, under required limits.
- `Mica::Testing` (opt-in, `require "mica/testing"`): the complexity,
  fuzzing and requirement-traceability harnesses every format uses.

More formats (JSON, YAML, CBOR, COSE, HTTP/1.1, URIs, multipart, CSV, TOML,
Markdown) plug into the same core; see
[docs/ADDING_A_FORMAT.md](docs/ADDING_A_FORMAT.md).

Mica has no C parsing dependencies: no libxml2 and no regex engine. A Mica
program links only libgc, libiconv and libSystem, which the Crystal runtime
itself needs (`scripts/check_linkage.sh` checks this). Mica never reads the
network or the file system while parsing, and it is secure by default:
every parse and every XPath evaluation runs in time linear in its input,
under a work budget and a deadline.

The XML API follows stdlib `XML` closely; porting is mostly renaming `XML`
to `Mica::XML`.

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
document = Mica::XML.parse(File.read("feed.xml")) # String, Bytes or IO
feed = document.root || raise "empty document"      # Mica::XML::Node
feed.name                                           # local name, like stdlib
feed["version"]?                                    # attribute or nil
feed.children.select(&.element?)
document.xpath_nodes("//item/title").map(&.content)
```

`Mica::XML::Node` is a small struct (document + index); nodes live in an
arena owned by `Mica::XML::Document`. It supports the stdlib `XML::Node`
API: `[]`, `[]?`, `[]=`, `delete`, `attributes`, `children`,
`content`/`text`/`inner_text`, `content=`, `name`, `name=`, `namespace`,
`namespaces`, `namespace_definitions`, `namespace_scopes`, `parent`,
`next`/`previous` (and `_sibling`/`_element` forms), `first_element_child`,
`root`, `type` and the type predicates, `unlink`, `to_s`,
`to_xml(indent:, indent_text:)`, and the XPath methods. Extras:
`qualified_name`, `prefix`, `namespace_uri`.

## Streaming with the reader

```crystal
File.open("s3-listing.xml") do |file|
  reader = Mica::XML::Reader.new(file)
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
`read_inner_xml`, `read_outer_xml`, `line_number`, `column_number`,
`renew_meter` (see the work budget below).

## Building XML

```crystal
xml = Mica::XML.build(indent: 2) do |builder|
  builder.element("ListBucketResult", xmlns: "http://s3.amazonaws.com/doc/2006-03-01/") do
    builder.element("Key") { builder.text "photos/a&b.jpg" }
  end
end
```

The builder escapes text and attribute values, checks names and
characters, splits `]]>` in CDATA, and raises `Mica::XML::BuilderError` for
misuse (an attribute after content, a second root, a `--` in a comment).
Methods match stdlib `XML::Builder`. It writes UTF-8 only, and when writing
XML 1.1 it escapes control characters as character references.

## Forms and query strings

`Mica::Form` parses `application/x-www-form-urlencoded` bodies and URL
query strings. Every entry point takes a required `limits:` argument, so
each call site states its limits:

```crystal
require "mica"

limits = Mica::Form::Limits::REQUEST_BODY # or QUERY_STRING, or Limits.new(...)

pairs = Mica::Form::Pairs.parse("a=1&b=x+y&a=%C3%A9", limits: limits)
pairs.fetch_all("a") # => ["1", "é"]
pairs.to_s           # => "a=1&b=x+y&a=%C3%A9"

value = Mica::Form.parse("user[name]=Ada&user[tags][]=x&items[2]=c", limits: limits)
value["user"]["name"].as_s             # => "Ada"
value["user"]["tags"].as_a.map(&.as_s) # => ["x"]
value["items"].as_a.size               # => 3 (nil, nil, "c")
```

- `Pairs` follows the WHATWG urlencoded parser and serializer. By default
  decoded bytes must be valid UTF-8: where WHATWG substitutes U+FFFD,
  Mica raises `Mica::EncodingError` at the byte where the invalid sequence
  starts. Pass `invalid_utf8: :replace_like_browsers` to substitute U+FFFD
  exactly as browsers do (see "Invalid UTF-8 in forms" below). Stdlib
  `URI::Params` passes invalid UTF-8 through into its strings and also
  splits on `;`.
- `NestedKeys` implements the Rack bracket convention with an explicit
  grammar (documented on the class): `a[b][c]`, `a[]` (append), `a[0]`
  (index), Rack's `a[][x]` rule and dot keys `a.b.c`. Malformed keys raise
  `Mica::Form::KeySyntaxError`; keys that need different kinds of value at
  one path raise `Mica::Form::KeyConflictError`. Nothing is silently
  skipped.
- Limits: `max_input_bytes` (2 MiB for a request body), `max_pairs`
  (1,000), `max_key_depth` (32), `max_array_index` (1,000; `a[999999999]`
  is rejected at once, with no allocation), `max_array_slots` (10,000 in
  the whole result) and a work budget with a 5 second deadline.
  `Limits.unbounded(reason: "...")` turns them off for trusted input.
- Parsing is linear in the input (`spec/form/complexity_spec.cr` checks 18
  adversarial shapes by operation count at n and 8n, three of them with
  `invalid_utf8: :replace_like_browsers`).

### Invalid UTF-8 in forms

Every form entry point (`Mica::Form.parse`, `Pairs.parse`, `Pairs.each`,
`NestedKeys.build`, `NestedKeys.new`) takes `invalid_utf8:`, with one of
two values (`Mica::Form::InvalidUTF8Handling`):

| `invalid_utf8:` | What happens to invalid UTF-8 | Pick it when |
|---|---|---|
| `:reject` (the default) | Raises `Mica::EncodingError` at the byte where the invalid sequence starts | APIs, webhooks, signed or hashed data: no byte is ever swapped for U+FFFD, so the text your code sees decodes exactly what was signed, or the parse fails |
| `:replace_like_browsers` | Each invalid sequence becomes U+FFFD, exactly as the WHATWG parser and browsers do (one U+FFFD per maximal subpart) | You must accept what a browser would accept from real-world forms, such as legacy pages that send Latin-1 or Windows-1252 bytes |

Reject (the default) for a webhook whose signature you check. Verify the
signature over the raw body bytes first, then parse:

```crystal
# The HMAC over body.to_slice was checked before this point.
begin
  event = Mica::Form.parse(body, limits: Mica::Form::Limits::REQUEST_BODY)
rescue error : Mica::EncodingError
  # error.message: "Invalid UTF-8 in form value at byte 12 (...); pass
  # invalid_utf8: :replace_like_browsers to accept it the way browsers do
  # (each invalid sequence becomes U+FFFD) (byte 12)"
  # Refuse the request: the body is not the text that was signed.
  raise error
end
```

Replace for a form posted from a legacy page, and check whether anything
was replaced:

```crystal
require "log"
require "mica"

value = Mica::Form.parse("city=M%FCnchen&zip=80331",
  limits: Mica::Form::Limits::REQUEST_BODY,
  invalid_utf8: :replace_like_browsers)
value["city"].as_s                # => "M\uFFFDnchen"
value.has_replaced_invalid_bytes? # => true (ask the root about the whole parse)
value["zip"].has_replaced_invalid_bytes? # => false

pairs = Mica::Form::Pairs.parse("q=caf%E9", limits: Mica::Form::Limits::QUERY_STRING,
  invalid_utf8: :replace_like_browsers)
Log.warn { "query string had invalid UTF-8 replaced" } if pairs.has_replaced_invalid_bytes?
```

`has_replaced_invalid_bytes?` exists on `Pair`, `Pairs` (any pair) and
`Value` (any pair that reached that node, even when a later value for the
same key won; the root covers the whole parse), and is always false under
`:reject` when Mica parses raw input (a pair Mica replaced earlier keeps its
mark). Limits count the bytes before replacement, so the
up-to-threefold growth from U+FFFD never trips `max_input_bytes`.

`Mica::EncodingError#byte_offset` is the input byte where the invalid
sequence starts for `Pairs` and `Mica::Form.parse`. For a `Pair` built in
code and passed to `NestedKeys`, it is the pair's `byte_offset`, and the
message names the byte within the name or value.

## Security and limits

Every parse is secure by default:

- External DTD subsets and external entities (general and parameter) are
  never fetched. A reference to an external parsed entity in content is
  reported as an `ENTITY_REFERENCE` node and kept as `&name;` on output.
- Entity expansion is bounded by count and by total bytes; attributes added
  from DTD defaults have their own count and byte limits; entity nesting
  and element nesting are bounded; recursion is a well-formedness error.
- Token size, name length, attributes per element and total input size are
  bounded. The parser is iterative, as are the serializer and the XPath
  axes, so deep documents cannot overflow the stack.
- Every parse and every XPath evaluation runs in time linear in its input.
  The specs prove it with operation counts at n and 4n for every pattern
  that is superlinear in other parsers, including the REXML 2024 CVE
  inputs (CVE-2024-35176, -39908, -41123, -41946, -43398 and -49761).
  Mica's name table caps its hash probes outright; other hash-table steps
  count as one operation in expectation, because Crystal keys its hashing
  with a secure random seed chosen once per process.
- Scanners and node storage read memory only through bounds-checked
  slices.

### Work budget and deadline

Each parse and each XPath evaluation counts its work in abstract operations
(about one per byte scanned, plus one per step of any loop that does not
advance through the input) against a `Mica::Core::WorkBudget`:

    allowance = base_operations + operations_per_unit * units

The units are the input bytes for a parse, and the document's nodes plus
the expression's bytes for XPath. A timeout adds a wall-clock deadline,
checked at least every 65,536 operations, at every read from a stream, and
when each XPath compilation, evaluation and edit starts (and, for compilation
and evaluation, before it returns).

| Operation | Default budget | Default deadline | Measured cost of valid input |
|---|---|---|---|
| Parse (`ParserOptions::DEFAULT_WORK_BUDGET`) | 1,000,000 + 64 per byte | 60 s | at most 5.6 operations per byte (fuzz maximum over 2M cases) |
| XPath (`XPath::DEFAULT_WORK_BUDGET`) | 1,000,000 + 64 per node | 10 s | about 2 operations per node for `count(//*)` |
| DOM edits (`Document::DEFAULT_EDIT_BUDGET`) | 1,000,000 + 64 per node, name byte, edit call and byte given to edits | none | a few operations per edit |

The defaults leave more than ten times headroom over the most expensive
valid input that the fuzzer and the benchmarks found, and they stop any
input that needs superlinear work. When a budget trips, Mica raises
`Mica::WorkBudgetExceededError` (with `operations` and `allowance`) or
`Mica::DeadlineExceededError` (with `elapsed`). Both are
`Mica::LimitExceededError`s and carry the position where the work stopped,
in the document or in the XPath expression.

```crystal
options = Mica::XML::ParserOptions.new(
  namespace_aware: true,
  max_entity_expansions: 10_000,                 # default
  max_entity_expansion_bytes: 16 * 1024 * 1024,  # default
  max_entity_depth: 16,                          # default
  max_default_attributes: 1_000_000,             # default
  max_default_attribute_bytes: 16 * 1024 * 1024, # default
  max_element_depth: 1024,                       # default
  max_name_bytes: 50_000,                        # default
  max_attributes: 10_000,                        # default
  max_token_bytes: 10 * 1024 * 1024,             # default
  max_input_bytes: nil,                          # default: no cap
  work_budget: Mica::Core::WorkBudget.new(operations_per_unit: 64, timeout: 2.seconds),
  check_normalization: false,                    # default; XML 1.1 section 2.13
)
Mica::XML.parse(body, options)

# One meter shared by a parse and the queries that follow it. Each call
# adds its own input to the allowance (a query re-reads the document), so a
# request that makes many calls is bounded by max_operations or a timeout:
meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.new(timeout: 1.second))
document = Mica::XML.parse(body, meter: meter)
document.xpath_nodes("//item", meter: meter)
```

Edits through `Node` (`[]=`, `delete`, `name=`, `content=`, `unlink`) are
charged to `Document#edit_meter`, whose units are the document's nodes and
name bytes plus one per edit call and the bytes each call is given; a
document edited in rounds over a long life calls
`Document#renew_edit_meter` between rounds.

A long-lived stream (a protocol session over a socket) calls
`Reader#renew_meter` between messages instead of disabling the budget. The
deadline is checked whenever the reader asks its IO for more bytes; a read
that blocks forever never returns to Mica, so give sockets a read timeout
(`IO#read_timeout`).

## Errors

All errors inherit from `Mica::Error`:

| Error | Raised for |
|---|---|
| `Mica::ParseError` | well-formedness or namespace errors; has `position` (`byte_offset`, `line_number`, `column_number` in characters) and `detail` |
| `Mica::EncodingError` | unsupported encodings and invalid UTF-8 or UTF-16, at the exact source byte (subclass of `ParseError`) |
| `Mica::LimitExceededError` | a `ParserOptions` limit (subclass of `ParseError`) |
| `Mica::WorkBudgetExceededError` | the work budget (subclass of `LimitExceededError`) |
| `Mica::DeadlineExceededError` | the deadline (subclass of `LimitExceededError`) |
| `Mica::XML::NormalizationError` | XML 1.1 text that is not fully normalized, with `check_normalization` (subclass of `ParseError`) |
| `Mica::XML::XPathError` | XPath syntax errors and unsupported XPath features |
| `Mica::XML::BuilderError` | builder misuse |

## Encodings

`Mica::XML` decodes UTF-8 (with or without a byte order mark), UTF-16 (big
or little endian, byte order mark required) and ISO-8859-1 in Crystal;
`US-ASCII` is accepted and enforced. Invalid input is never replaced with
U+FFFD: it raises `Mica::EncodingError` at the offset of the bad byte in the
original input. UTF-32, EBCDIC and any other declared encoding raise
`Mica::EncodingError` naming it. (`Mica::Core::Transcoder` also decodes
UTF-32, for formats that allow it.)

## XML 1.1

A document that declares `version="1.1"` follows the XML 1.1 rules: NEL
(U+0085), LSEP (U+2028), CR NEL and CR LF become LF in the document entity;
character references may name C0 controls other than NUL; DEL and the C1
controls other than NEL may not appear literally; names use the XML 1.1
ranges; and `xmlns:p=""` undeclares a prefix (Namespaces 1.1).
`check_normalization: true` verifies full normalization (section 2.13):
names, attribute values, character content, CDATA sections, comments and
PIs must be in Unicode NFC and must not start with a composing character.

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
the prefix `xmlns`), as in stdlib. `Mica::XML::XPath.compile(path)` returns
a reusable expression. Every evaluation takes `budget:` and `meter:` named
arguments (see the work budget above).

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
- Unsupported features and unknown functions raise `Mica::XML::XPathError`.
- Evaluation is linear in the document for every axis from any number of
  context nodes, for node-set comparisons and for the string functions
  (`contains` and its relatives use Knuth-Morris-Pratt search). Number
  conversion handles digit strings of any length in linear time.

## Development

```sh
shards-alpha install --frozen
# Build and run the specs: complexity, hostile bytes, fuzzing, XML 1.1,
# budgets, core, testing harnesses and requirement traceability
crystal-alpha build $(find spec -name '*_spec.cr' | sort) -o bin/specs && bin/specs
crystal-alpha tool format --check
bin/ameba                    # build: crystal-alpha build lib/ameba/bin/ameba.cr -o bin/ameba
scripts/check_linkage.sh     # no Regex in src; otool -L of a minimal program

# Reports from the spec run
MICA_COMPLEXITY_REPORT=complexity.tsv MICA_TRACEABILITY_REPORT=traceability.tsv bin/specs

# W3C XML Conformance Test Suite (xmlconf 2013-09-23,
# sha256 9b61db9f5dbffa545f4b8d78422167083a8568c59bd1129f94138f936cf6fc1f);
# scores the XML 1.0 and XML 1.1 suites separately
crystal-alpha run --release conformance/run.cr -- /path/to/xmlconf
crystal-alpha run --release conformance/run_libxml2.cr -- /path/to/xmlconf   # baseline

# Fuzz campaigns (release build) and the libxml2 differential
crystal-alpha build --release fuzz/campaign.cr -o bin/fuzz_campaign
bin/fuzz_campaign SEED ITERATIONS [FIRST]
MICA_FUZZ_SEED=7 MICA_FUZZ_ITERATIONS=300000 crystal-alpha spec spec/xml/fuzz_spec.cr
crystal-alpha run --release fuzz/differential.cr -- 20261024 20000

# Mica::Form: the web-platform-tests urlencoded vectors (pinned by commit
# and sha256 in conformance/form/wpt_urlencoded.json), the release fuzz
# campaign (with the stdlib URI::Params differential) and the benchmark
# against stdlib URI::Params
crystal-alpha run --release conformance/form/run.cr
crystal-alpha build --release fuzz/form_campaign.cr -o bin/form_fuzz_campaign
bin/form_fuzz_campaign SEED ITERATIONS [FIRST]
bench/form_run.sh

# Benchmarks against stdlib XML (libxml2)
crystal-alpha run --release bench/generate.cr
bench/run.sh
```

Requirement ids in `spec/requirements/*.tsv` map specification sections and
Mica's hardening requirements to the specs that cover them; specs declare
them with `it_satisfies "ID", "description"`.

The libxml2 comparison programs (`conformance/run_libxml2.cr`,
`bench/bench_stdlib.cr`, `fuzz/differential.cr`) are the only code that
requires stdlib `xml`; the library and its specs never link libxml2.

## License

MIT
