#!/bin/sh
# Builds libnghttp2 1.71.0 (the library only, static, -O2) out of tree from its release
# tarball, checked by sha256, and links harness.c against it.
#
#   fuzz/hpack_nghttp2/build.sh WORK_DIR
#
# WORK_DIR receives the tarball, the build and bin/hpack_nghttp2. The
# tarball's sha256 is the digest GitHub publishes for the release asset.
set -eu
WORK=$1
VERSION=1.71.0
SHA256=c0f55121d88650e4b9227aec28cebaf664d2417ca60fe70be0f8d38829f52116
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$WORK" && cd "$WORK"
TARBALL=nghttp2-$VERSION.tar.xz
[ -f "$TARBALL" ] || curl -sSfL -A 'AgentC-Consulting-research/1.0 (+https://agentc.consulting; agent_c@agentc.consulting)' \
  -o "$TARBALL" "https://github.com/nghttp2/nghttp2/releases/download/v$VERSION/$TARBALL"
ACTUAL=$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)
[ "$ACTUAL" = "$SHA256" ] || { echo "sha256 mismatch: $ACTUAL"; rm -f "$TARBALL"; exit 1; }
rm -rf src build prefix bin && mkdir src build prefix bin
tar xJf "$TARBALL" -C src --strip-components 1
# The library sources are compiled directly (no configure, which needs
# pkg-config): every lib/*.c with the version header filled in.
sed -e "s/@PACKAGE_VERSION@/$VERSION/" -e "s/@PACKAGE_VERSION_NUM@/0x014700/" \
  src/lib/includes/nghttp2/nghttp2ver.h.in >src/lib/includes/nghttp2/nghttp2ver.h
mkdir -p prefix/include/nghttp2 prefix/lib
cp src/lib/includes/nghttp2/nghttp2.h src/lib/includes/nghttp2/nghttp2ver.h prefix/include/nghttp2/
for source in src/lib/*.c; do
  cc -O2 -DNDEBUG -DBUILDING_NGHTTP2 -Isrc/lib -Isrc/lib/includes -Isrc/third-party -c "$source" -o "build/$(basename "$source" .c).o"
done
ar rcs prefix/lib/libnghttp2.a build/*.o
cc -O2 -I"$WORK/prefix/include" -o bin/hpack_nghttp2 "$HERE/harness.c" "$WORK/prefix/lib/libnghttp2.a"
echo "built $WORK/bin/hpack_nghttp2 against nghttp2 $VERSION (sha256 $SHA256)"
