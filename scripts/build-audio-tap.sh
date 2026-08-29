#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew was not found: https://brew.sh" >&2
  exit 1
fi

BARESIP_PREFIX=${BARESIP_PREFIX:-$(brew --prefix baresip 2>/dev/null || true)}
LIBRE_PREFIX=${LIBRE_PREFIX:-$(brew --prefix libre 2>/dev/null || true)}
SPANDSP_PREFIX=${SPANDSP_PREFIX:-$(brew --prefix spandsp 2>/dev/null || true)}
OPUS_PREFIX=${OPUS_PREFIX:-$(brew --prefix opus 2>/dev/null || true)}

if [ -z "$BARESIP_PREFIX" ] || [ ! -d "$BARESIP_PREFIX/lib/baresip/modules" ]; then
  echo "baresip was not found. Install it with: brew install baresip" >&2
  exit 1
fi
if [ -z "$LIBRE_PREFIX" ] || [ ! -d "$LIBRE_PREFIX/include/re" ]; then
  echo "libre was not found. Install it with: brew install libre" >&2
  exit 1
fi

MODULES="$ROOT/runtime/modules"
mkdir -p "$MODULES"
for module in "$BARESIP_PREFIX"/lib/baresip/modules/*.so; do
  ln -sfn "$module" "$MODULES/$(basename "$module")"
done

xcrun clang \
  -std=c11 -O2 -Wall -Wextra -Werror \
  -bundle -undefined dynamic_lookup \
  -I"$BARESIP_PREFIX/include" \
  -I"$LIBRE_PREFIX/include/re" \
  "$ROOT/Modules/phone_tap/phone_tap.c" \
  -o "$MODULES/phone_tap.so"

codesign --force --sign - "$MODULES/phone_tap.so"
echo "Built: $MODULES/phone_tap.so"

G722_SOURCE="$ROOT/Modules/g722/g722.c"
G722_ARCHIVE="$ROOT/.build/source-cache/baresip-v4.11.0.tar.gz"
G722_CHECKSUM=e170ad5857994dfed0c84c4c04eb904fa410f3ec2d5a6c789b50b3fda47ba98c
rm -f "$MODULES/g722.so"

if [ ! -f "$G722_SOURCE" ]; then
  brew_archive=$(brew --cache --build-from-source baresip 2>/dev/null || true)
  if [ -f "$brew_archive" ]; then
    G722_ARCHIVE=$brew_archive
  elif [ ! -f "$G722_ARCHIVE" ]; then
    mkdir -p "$(dirname "$G722_ARCHIVE")"
    if ! curl -fL --connect-timeout 10 --retry 1 \
      https://github.com/baresip/baresip/archive/refs/tags/v4.11.0.tar.gz \
      -o "$G722_ARCHIVE"; then
      rm -f "$G722_ARCHIVE"
    fi
  fi
  if [ -f "$G722_ARCHIVE" ]; then
    actual_checksum=$(shasum -a 256 "$G722_ARCHIVE" | awk '{print $1}')
    if [ "$actual_checksum" = "$G722_CHECKSUM" ]; then
      mkdir -p "$(dirname "$G722_SOURCE")"
      tar -xzf "$G722_ARCHIVE" -C "$(dirname "$G722_SOURCE")" \
        --strip-components 3 baresip-4.11.0/modules/g722/g722.c
      echo "Vendored: $G722_SOURCE"
    else
      echo "Skipping g722.so: baresip v4.11.0 source checksum did not match" >&2
    fi
  fi
fi

if [ ! -f "$G722_SOURCE" ]; then
  echo "Skipping g722.so: baresip v4.11.0 module source is unavailable" >&2
elif [ -z "$SPANDSP_PREFIX" ] || [ ! -f "$SPANDSP_PREFIX/include/spandsp.h" ] || \
     [ ! -f "$SPANDSP_PREFIX/lib/libspandsp.a" ]; then
  echo "Skipping g722.so: Homebrew spandsp is unavailable" >&2
else
  xcrun clang \
    -std=c11 -O2 -Wall -Wextra -Werror \
    -bundle -undefined dynamic_lookup \
    -I"$BARESIP_PREFIX/include" \
    -I"$LIBRE_PREFIX/include/re" \
    -I"$SPANDSP_PREFIX/include" \
    -I"$(brew --prefix libtiff)/include" \
    "$G722_SOURCE" \
    "$SPANDSP_PREFIX/lib/libspandsp.a" \
    -o "$MODULES/g722.so"
  codesign --force --sign - "$MODULES/g722.so"
  echo "Built: $MODULES/g722.so"
fi

OPUS_SOURCE_DIR="$ROOT/Modules/opus"
OPUS_ARCHIVE="$ROOT/.build/source-cache/baresip-v4.11.0.tar.gz"
OPUS_CHECKSUM=e170ad5857994dfed0c84c4c04eb904fa410f3ec2d5a6c789b50b3fda47ba98c
OPUS_SOURCES="decode.c encode.c opus.c opus.h sdp.c"
rm -f "$MODULES/opus.so"

opus_sources_available=yes
for source in $OPUS_SOURCES; do
  if [ ! -f "$OPUS_SOURCE_DIR/$source" ]; then
    opus_sources_available=no
  fi
done

if [ "$opus_sources_available" = no ]; then
  brew_archive=$(brew --cache --build-from-source baresip 2>/dev/null || true)
  if [ -f "$brew_archive" ]; then
    OPUS_ARCHIVE=$brew_archive
  elif [ ! -f "$OPUS_ARCHIVE" ]; then
    mkdir -p "$(dirname "$OPUS_ARCHIVE")"
    if ! curl -fL --connect-timeout 10 --retry 1 \
      https://github.com/baresip/baresip/archive/refs/tags/v4.11.0.tar.gz \
      -o "$OPUS_ARCHIVE"; then
      rm -f "$OPUS_ARCHIVE"
    fi
  fi
  if [ -f "$OPUS_ARCHIVE" ]; then
    actual_checksum=$(shasum -a 256 "$OPUS_ARCHIVE" | awk '{print $1}')
    if [ "$actual_checksum" = "$OPUS_CHECKSUM" ]; then
      mkdir -p "$OPUS_SOURCE_DIR"
      tar -xzf "$OPUS_ARCHIVE" -C "$OPUS_SOURCE_DIR" \
        --strip-components 3 \
        baresip-4.11.0/modules/opus/decode.c \
        baresip-4.11.0/modules/opus/encode.c \
        baresip-4.11.0/modules/opus/opus.c \
        baresip-4.11.0/modules/opus/opus.h \
        baresip-4.11.0/modules/opus/sdp.c
      echo "Vendored: $OPUS_SOURCE_DIR"
    else
      echo "Skipping opus.so: baresip v4.11.0 source checksum did not match" >&2
    fi
  fi
fi

opus_sources_available=yes
for source in $OPUS_SOURCES; do
  if [ ! -f "$OPUS_SOURCE_DIR/$source" ]; then
    opus_sources_available=no
  fi
done

if [ "$opus_sources_available" = no ]; then
  echo "Skipping opus.so: baresip v4.11.0 module source is unavailable" >&2
elif [ -z "$OPUS_PREFIX" ] || [ ! -f "$OPUS_PREFIX/include/opus/opus.h" ] || \
     [ ! -f "$OPUS_PREFIX/lib/libopus.a" ]; then
  echo "Skipping opus.so: Homebrew opus static library is unavailable" >&2
else
  xcrun clang \
    -std=c11 -O2 -Wall -Wextra -Werror \
    -bundle -undefined dynamic_lookup \
    -I"$BARESIP_PREFIX/include" \
    -I"$LIBRE_PREFIX/include/re" \
    -I"$OPUS_PREFIX/include" \
    "$OPUS_SOURCE_DIR/decode.c" \
    "$OPUS_SOURCE_DIR/encode.c" \
    "$OPUS_SOURCE_DIR/opus.c" \
    "$OPUS_SOURCE_DIR/sdp.c" \
    "$OPUS_PREFIX/lib/libopus.a" \
    -o "$MODULES/opus.so"
  codesign --force --sign - "$MODULES/opus.so"
  echo "Built: $MODULES/opus.so"
fi
