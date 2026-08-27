#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew was not found: https://brew.sh" >&2
  exit 1
fi

BARESIP_PREFIX=${BARESIP_PREFIX:-$(brew --prefix baresip 2>/dev/null || true)}
LIBRE_PREFIX=${LIBRE_PREFIX:-$(brew --prefix libre 2>/dev/null || true)}

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
