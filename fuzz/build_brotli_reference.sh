#!/bin/sh
# Builds the reference for the Brotli differential and benchmark out of
# tree: google/brotli v1.2.1 from its release tarball, checked by sha256,
# into DIR/libbrotli.a and DIR/brotli. Mica itself never links it.
#
#   fuzz/build_brotli_reference.sh DIR
set -eu
DIR=${1:?usage: fuzz/build_brotli_reference.sh DIR}
URL=https://github.com/google/brotli/archive/refs/tags/v1.2.1.tar.gz
SHA256=98d35d11a78dc453aebb7d10c3748f3f73ff78c8267c0dc697b8631f67bf7e8f
mkdir -p "$DIR/src"
cd "$DIR"
[ -f brotli-1.2.1.tar.gz ] || curl -sSfL -A "AgentC-Consulting-research/1.0 (+https://agentc.consulting; agent_c@agentc.consulting)" -o brotli-1.2.1.tar.gz "$URL"
echo "$SHA256  brotli-1.2.1.tar.gz" | shasum -a 256 -c -
tar xzf brotli-1.2.1.tar.gz -C src --strip-components 1
mkdir -p obj
for f in src/c/common/*.c src/c/dec/*.c src/c/enc/*.c; do
  cc -O3 -c -Isrc/c/include "$f" -o "obj/$(basename "$(dirname "$f")")_$(basename "$f" .c).o"
done
ar rcs libbrotli.a obj/*.o
cc -O3 -Isrc/c/include src/c/tools/brotli.c libbrotli.a -o brotli
./brotli --version
