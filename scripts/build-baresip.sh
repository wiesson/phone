#!/bin/sh
# Builds libre and baresip from the release sources Homebrew has already
# verified, into .build/deps. The App Store wants every executable and
# library in the bundle signed with our identity and built against our
# deployment target; Homebrew's bottles are neither. build-app.sh picks the
# result up through BARESIP_PREFIX and LIBRE_PREFIX.
#
#   sh scripts/build-baresip.sh            # build if missing
#   sh scripts/build-baresip.sh --force    # rebuild
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
PREFIX="$ROOT/.build/deps"
SOURCES="$ROOT/.build/deps-src"
DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-26.0}
STAMP="$PREFIX/.built"

if [ "${1:-}" != "--force" ] && [ -f "$STAMP" ] && [ -x "$PREFIX/bin/baresip" ]; then
  echo "baresip is already built at $PREFIX (use --force to rebuild)"
  exit 0
fi

for tool in brew cmake; do
  command -v "$tool" >/dev/null 2>&1 || { echo "$tool was not found" >&2; exit 1; }
done

OPENSSL_PREFIX=${OPENSSL_PREFIX:-$(brew --prefix openssl@4 2>/dev/null || brew --prefix openssl@3)}
[ -d "$OPENSSL_PREFIX/lib" ] || { echo "OpenSSL was not found. Install it with: brew install openssl@4" >&2; exit 1; }

# Homebrew downloads the release tarballs and checks them against the
# checksums in its formulae; this script never fetches anything itself.
brew fetch --build-from-source libre baresip >/dev/null
RE_TARBALL=$(brew --cache --build-from-source libre)
BARESIP_TARBALL=$(brew --cache --build-from-source baresip)
[ -f "$RE_TARBALL" ] && [ -f "$BARESIP_TARBALL" ] || { echo "Source tarballs were not downloaded" >&2; exit 1; }

rm -rf "$SOURCES" "$PREFIX"
mkdir -p "$SOURCES" "$PREFIX"
tar -xzf "$RE_TARBALL" -C "$SOURCES"
tar -xzf "$BARESIP_TARBALL" -C "$SOURCES"
RE_DIR=$(find "$SOURCES" -maxdepth 1 -type d -name 're-*' | head -1)
BARESIP_DIR=$(find "$SOURCES" -maxdepth 1 -type d -name 'baresip-*' | head -1)
[ -n "$RE_DIR" ] && [ -n "$BARESIP_DIR" ] || { echo "Unexpected tarball layout under $SOURCES" >&2; exit 1; }
echo "libre:   $RE_DIR"
echo "baresip: $BARESIP_DIR"

JOBS=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)

cmake -S "$RE_DIR" -B "$RE_DIR/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
  -DCMAKE_INSTALL_RPATH="$PREFIX/lib" \
  -DOPENSSL_ROOT_DIR="$OPENSSL_PREFIX" \
  >/dev/null
cmake --build "$RE_DIR/build" -j "$JOBS" >/dev/null
cmake --install "$RE_DIR/build" >/dev/null

# Exactly the modules the bundled config and the app use. g722 is left out
# on purpose: it links spandsp (LGPL), which the App Store build cannot
# carry. opus and phone_tap are built by build-audio-tap.sh from vendored
# sources, statically against libopus.
MODULES=${BARESIP_MODULES:-"stdio;g711;auconv;auresamp;coreaudio;avcapture;uuid;stun;turn;ice;srtp;account;contact;debug_cmd;menu;netroam;aubridge;in_band_dtmf"}
cmake -S "$BARESIP_DIR" -B "$BARESIP_DIR/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
  -DCMAKE_INSTALL_RPATH="$PREFIX/lib" \
  -DCMAKE_PREFIX_PATH="$PREFIX;$OPENSSL_PREFIX" \
  -DRE_INCLUDE_DIR="$PREFIX/include/re" \
  -DOPENSSL_ROOT_DIR="$OPENSSL_PREFIX" \
  -DMODULES="$MODULES" \
  -DCMAKE_EXE_LINKER_FLAGS=-Wl,-dead_strip_dylibs \
  -DCMAKE_SHARED_LINKER_FLAGS=-Wl,-dead_strip_dylibs \
  >/dev/null
cmake --build "$BARESIP_DIR/build" -j "$JOBS" >/dev/null
cmake --install "$BARESIP_DIR/build" >/dev/null

[ -x "$PREFIX/bin/baresip" ] || { echo "baresip did not build" >&2; exit 1; }
for module in $(printf '%s' "$MODULES" | tr ';' ' '); do
  [ -f "$PREFIX/lib/baresip/modules/$module.so" ] || { echo "Module did not build: $module" >&2; exit 1; }
done
if [ -f "$PREFIX/lib/baresip/modules/g722.so" ]; then
  echo "g722.so was built although it must not ship" >&2
  exit 1
fi

date > "$STAMP"
echo "Built: $PREFIX/bin/baresip ($("$PREFIX/bin/baresip" -h 2>&1 | head -1))"
echo "Use it with: BARESIP_PREFIX=$PREFIX LIBRE_PREFIX=$PREFIX sh scripts/build-app.sh"
