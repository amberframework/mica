#!/bin/sh
# Prints which zlib the Mica::Deflate differential oracle links
# (fuzz/deflate_oracle.cr), for the campaign's evidence:
#
# - zlibVersion() as a tiny program linked the way the harness links it;
# - on macOS: the sha256 of the SDK's libz.tbd (what the linker reads), the
#   UUID and install name of /usr/lib/libz.1.dylib in the dyld shared cache
#   (what runs), and the macOS build;
# - on Linux: the resolved libz path, its sha256 and the package version.
#
# usage: scripts/zlib_oracle_identity.sh [OUTPUT_DIR]
set -eu
cd "$(dirname "$0")/.."
out=${1:-${TMPDIR:-/tmp}/mica-zlib-identity}
mkdir -p "$out"
out=$(cd "$out" && pwd)

cat > "$out/zlib_version.cr" <<'CRYSTAL'
@[Link("z")]
lib LibZIdentity
  fun zlibVersion : LibC::Char*
end

STDOUT << "zlibVersion: " << String.new(LibZIdentity.zlibVersion) << '\n'
CRYSTAL
crystal-alpha build "$out/zlib_version.cr" -o "$out/zlib_version"
"$out/zlib_version"

case "$(uname -s)" in
Darwin)
  sdk=$(xcrun --show-sdk-path)
  echo "sdk: $sdk ($(xcrun --show-sdk-version))"
  echo "libz.tbd sha256: $(shasum -a 256 "$sdk/usr/lib/libz.tbd" | awk '{print $1}')"
  echo "linked: $(otool -L "$out/zlib_version" | awk '/libz/ {print $1, $2, $3, $4, $5, $6, $7}')"
  echo "libz.1.dylib UUID (dyld shared cache): $(dyld_info -uuid /usr/lib/libz.1.dylib | awk 'NF == 1 && $1 !~ /:/ {print $1}' | tr '\n' ' ')"
  dyld_info -load_commands /usr/lib/libz.1.dylib | awk '/LC_ID_DYLIB/ {found = 1} found && /name:/ {name = $2} found && /cur-vers:/ {print "libz.1.dylib install name: " name " (current version " $2 ")"; found = 0}'
  echo "macOS: $(sw_vers -productVersion) build $(sw_vers -buildVersion)"
  ;;
*)
  library=$(ldd "$out/zlib_version" | awk '/libz/ {print $3}')
  echo "linked: $library"
  echo "libz sha256: $(sha256sum "$(readlink -f "$library")" | awk '{print $1}') ($(readlink -f "$library"))"
  if command -v dpkg-query > /dev/null 2>&1; then
    echo "package: $(dpkg-query -W -f='${Package} ${Version}\n' zlib1g 2> /dev/null || echo unknown)"
  fi
  echo "kernel: $(uname -sr)"
  ;;
esac
