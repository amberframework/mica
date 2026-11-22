#!/bin/sh
# Checks that Mica needs no regex engine, no compression library and no C
# parsing library at run time.
#
# 1. No use of the standard library's Regex in the library source (src/).
#    Mica::Regex is Mica's own engine, comments may mention stdlib Regex, and
#    RegexLiteral (the macro AST node `Mica::Regex.static` reads) is no engine.
# 2. A minimal Mica::XML program links only libgc (the Crystal garbage
#    collector), libiconv (linked by the Crystal runtime itself, for
#    String#encode; even `puts 1` links it) and libSystem.
# 3. A minimal Mica::Regex program links the same libraries, has no pcre2_
#    symbol (nm) and no PCRE2 entry in its linker map. A control program
#    that uses stdlib Regex, built the same way, shows all three, proving
#    the probes would catch PCRE2.
# 4. A minimal Mica::Gzip / Mica::Zlib program links the same libraries,
#    has no zlib symbol (inflate, deflate, crc32, adler32, zlibVersion),
#    no libz entry in its linker map and no PCRE2. A control program that
#    uses stdlib Compress::Gzip, built the same way, shows libz in all
#    three probes.
# 5. A minimal Mica::Gzip encoder program (one-shot and Writer, with zlib
#    and raw DEFLATE beside it, each decoded again) passes the same three
#    libz probes: the encoders link no libz either.
# 6. The spec binary links the same plus libpcre2-8 and libz: the standard
#    library's spec runner and the specs' expect_raises(..., /message/)
#    use Regex, and the differential specs use system zlib as the oracle.
#    No Mica code calls either.
#
# usage: scripts/check_linkage.sh [OUTPUT_DIR]   (macOS, otool -L and nm)
set -eu
cd "$(dirname "$0")/.."
out=${1:-${TMPDIR:-/tmp}/mica-linkage}
mkdir -p "$out"
out=$(cd "$out" && pwd)
status=0

stdlib_regex='Regex|=~|%r[({/]|\.(match|gsub|sub|scan)\('
if grep -rnE "$stdlib_regex" src | sed -E 's/Mica::Regex//g; s/RegexLiteral//g' |
  grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -E "$stdlib_regex"; then
  echo "FAIL: stdlib Regex use in src/"
  status=1
else
  echo "ok: no stdlib Regex in src/"
fi

crystal-alpha build --release scripts/linkage/minimal_xml.cr -o "$out/minimal_xml"
crystal-alpha build --release scripts/linkage/minimal_regex.cr -o "$out/minimal_regex" \
  --link-flags="-Wl,-map,$out/minimal_regex.map"
crystal-alpha build --release scripts/linkage/stdlib_regex_control.cr -o "$out/stdlib_regex_control" \
  --link-flags="-Wl,-map,$out/stdlib_regex_control.map"
crystal-alpha build --release scripts/linkage/minimal_inflate.cr -o "$out/minimal_inflate" \
  --link-flags="-Wl,-map,$out/minimal_inflate.map"
crystal-alpha build --release scripts/linkage/minimal_deflate.cr -o "$out/minimal_deflate" \
  --link-flags="-Wl,-map,$out/minimal_deflate.map"
crystal-alpha build --release scripts/linkage/stdlib_compress_control.cr -o "$out/stdlib_compress_control" \
  --link-flags="-Wl,-map,$out/stdlib_compress_control.map"
# shellcheck disable=SC2046 # spec paths contain no spaces
crystal-alpha build $(find spec -name '*_spec.cr' | sort) -o "$out/spec_binary"

check() {
  binary=$1
  allowed=$2
  otool -L "$out/$binary" | tail -n +2 | awk '{print $1}' > "$out/$binary.libs"
  echo "$binary links:"
  sed 's/^/  /' "$out/$binary.libs"
  unexpected=$(grep -vE "$allowed" "$out/$binary.libs" || true)
  if [ -n "$unexpected" ]; then
    echo "FAIL: $binary links unexpected libraries: $unexpected"
    status=1
  else
    echo "ok: $binary"
  fi
}

check minimal_xml '/libgc\.|/libiconv\.|/libSystem\.'
check minimal_regex '/libgc\.|/libiconv\.|/libSystem\.'
check minimal_inflate '/libgc\.|/libiconv\.|/libSystem\.'
check minimal_deflate '/libgc\.|/libiconv\.|/libSystem\.'
check spec_binary '/libgc\.|/libiconv\.|/libSystem\.|/libpcre2-8\.|/libz\.'
otool -L "$out/stdlib_regex_control" | tail -n +2 | awk '{print $1}' > "$out/stdlib_regex_control.libs"
if grep -q pcre "$out/minimal_xml.libs"; then
  echo "FAIL: minimal_xml links pcre"
  status=1
fi

for binary in minimal_regex stdlib_regex_control; do
  symbols=$(nm "$out/$binary" | grep -c pcre2_ || true)
  map_lines=$(grep -cE 'libpcre2|pcre2_[a-z0-9_]+' "$out/$binary.map" || true)
  libraries=$(grep -ci pcre2 "$out/$binary.libs" || true)
  echo "$binary: $symbols pcre2_ symbols, $map_lines PCRE2 linker-map lines, $libraries PCRE2 libraries"
  if [ "$binary" = minimal_regex ]; then
    if [ "$symbols" != 0 ] || [ "$map_lines" != 0 ] || [ "$libraries" != 0 ]; then
      echo "FAIL: minimal_regex reaches PCRE2"
      status=1
    else
      echo "ok: minimal_regex has no PCRE2 symbol, map entry or library"
    fi
  elif [ "$symbols" = 0 ] || [ "$map_lines" = 0 ] || [ "$libraries" = 0 ]; then
    echo "FAIL: the stdlib Regex control shows no PCRE2, so the probes prove nothing"
    status=1
  else
    echo "ok: the stdlib Regex control shows PCRE2 in all three probes"
  fi
done

zlib_symbols=' _(inflate|inflateInit2_|inflateEnd|deflate|deflateInit2_|deflateEnd|deflateBound|crc32|adler32|zlibVersion)$'
otool -L "$out/stdlib_compress_control" | tail -n +2 | awk '{print $1}' > "$out/stdlib_compress_control.libs"
for binary in minimal_inflate minimal_deflate stdlib_compress_control; do
  symbols=$(nm "$out/$binary" | grep -cE "$zlib_symbols" || true)
  map_lines=$(grep -cE '/libz[.0-9]*(dylib|tbd)' "$out/$binary.map" || true)
  libraries=$(grep -cE '/libz\.' "$out/$binary.libs" || true)
  pcre=$(nm "$out/$binary" | grep -c pcre2_ || true)
  echo "$binary: $symbols zlib symbols, $map_lines libz linker-map lines, $libraries libz libraries, $pcre pcre2_ symbols"
  if [ "$binary" != stdlib_compress_control ]; then
    if [ "$symbols" != 0 ] || [ "$map_lines" != 0 ] || [ "$libraries" != 0 ] || [ "$pcre" != 0 ]; then
      echo "FAIL: $binary reaches libz or PCRE2"
      status=1
    else
      echo "ok: $binary has no zlib symbol, map entry or library, and no PCRE2"
    fi
  elif [ "$symbols" = 0 ] || [ "$map_lines" = 0 ] || [ "$libraries" = 0 ]; then
    echo "FAIL: the stdlib Compress control shows no libz, so the probes prove nothing"
    status=1
  else
    echo "ok: the stdlib Compress control shows libz in all three probes"
  fi
done

"$out/minimal_xml" '<r><i/><i/></r>'
"$out/minimal_inflate"
"$out/minimal_deflate"
"$out/minimal_regex"
exit $status
