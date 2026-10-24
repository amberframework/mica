#!/bin/sh
# Checks that Mica needs no regex engine and no C parsing library at run time.
#
# 1. No Regex in the library source (src/).
# 2. A minimal Mica::XML program links only libgc (the Crystal garbage
#    collector), libiconv (linked by the Crystal runtime itself, for
#    String#encode; even `puts 1` links it) and libSystem.
# 3. The spec binary links the same plus libpcre2-8: the standard library's
#    spec runner and the specs' expect_raises(..., /message/) use Regex.
#    No Mica code calls it.
#
# usage: scripts/check_linkage.sh [OUTPUT_DIR]   (macOS, otool -L)
set -eu
cd "$(dirname "$0")/.."
out=${1:-${TMPDIR:-/tmp}/mica-linkage}
mkdir -p "$out"
status=0

if grep -rnE 'Regex|=~|%r[({/]|\.(match|gsub|sub|scan)\(' src; then
  echo "FAIL: Regex use in src/"
  status=1
else
  echo "ok: no Regex in src/"
fi

crystal-alpha build --release scripts/linkage/minimal_xml.cr -o "$out/minimal_xml"
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
check spec_binary '/libgc\.|/libiconv\.|/libSystem\.|/libpcre2-8\.'
if grep -q pcre "$out/minimal_xml.libs"; then
  echo "FAIL: minimal_xml links pcre"
  status=1
fi
"$out/minimal_xml" '<r><i/><i/></r>'
exit $status
