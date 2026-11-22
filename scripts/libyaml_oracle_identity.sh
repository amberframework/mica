#!/bin/sh
# Prints which libyaml the Mica::YAML differential oracle links
# (fuzz/yaml_oracle.cr), for the campaign's evidence:
#
# - yaml_get_version_string() from a tiny program linked the way the
#   harness links it;
# - the library file that program loads and its sha256;
# - the package that owns it (Homebrew on macOS, dpkg on Linux).
#
# The oracle is libyaml 0.2.5 (the version Amber apps link, and the one
# the libyaml dialect and spec/yaml/fixtures/libyaml_events.tsv follow).
# The script exits 1 when the linked library reports another version.
#
# usage: scripts/libyaml_oracle_identity.sh [OUTPUT_DIR]
set -eu
cd "$(dirname "$0")/.."
out=${1:-${TMPDIR:-/tmp}/mica-libyaml-identity}
mkdir -p "$out"
out=$(cd "$out" && pwd)
expected=0.2.5

cat > "$out/libyaml_version.cr" <<'CRYSTAL'
@[Link("yaml")]
lib LibYAMLIdentity
  fun yaml_get_version_string : LibC::Char*
end

STDOUT << String.new(LibYAMLIdentity.yaml_get_version_string) << '\n'
CRYSTAL
crystal-alpha build "$out/libyaml_version.cr" -o "$out/libyaml_version"
version=$("$out/libyaml_version")
echo "yaml_get_version_string: $version"

case "$(uname -s)" in
Darwin)
  library=$(otool -L "$out/libyaml_version" | awk '/yaml/ {print $1}')
  resolved=$(/usr/bin/ruby -e 'puts File.realpath(ARGV[0])' "$library")
  echo "linked: $library"
  echo "resolved: $resolved"
  echo "libyaml sha256: $(shasum -a 256 "$resolved" | awk '{print $1}')"
  if command -v brew > /dev/null 2>&1; then
    echo "package: $(brew list --versions libyaml 2> /dev/null || echo unknown)"
  fi
  echo "macOS: $(sw_vers -productVersion) build $(sw_vers -buildVersion)"
  ;;
*)
  library=$(ldd "$out/libyaml_version" | awk '/yaml/ {print $3}')
  echo "linked: $library"
  echo "libyaml sha256: $(sha256sum "$(readlink -f "$library")" | awk '{print $1}') ($(readlink -f "$library"))"
  if command -v dpkg-query > /dev/null 2>&1; then
    echo "package: $(dpkg-query -W -f='${Package} ${Version}\n' libyaml-0-2 2> /dev/null || echo unknown)"
  fi
  echo "kernel: $(uname -sr)"
  ;;
esac

if [ "$version" != "$expected" ]; then
  echo "FAIL: the oracle is libyaml $version, the campaign is pinned to $expected"
  exit 1
fi
echo "ok: the oracle is libyaml $expected"
