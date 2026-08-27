#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
ACCOUNT="$ROOT/runtime/baresip/accounts"
EXAMPLE="$ROOT/runtime/baresip/accounts.example"

missing=0
for command in xcrun swift brew; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Missing: $command" >&2
    missing=1
  fi
done

if [ "$missing" -ne 0 ]; then
  echo "Install the Xcode Command Line Tools and Homebrew, then run the setup again." >&2
  exit 1
fi

for formula in baresip libre; do
  if ! brew --prefix "$formula" >/dev/null 2>&1; then
    echo "Missing: $formula (install with: brew install $formula)" >&2
    missing=1
  fi
done

if [ "$missing" -ne 0 ]; then
  exit 1
fi

if [ ! -f "$ACCOUNT" ]; then
  cp "$EXAMPLE" "$ACCOUNT"
  echo "Created: runtime/baresip/accounts"
  echo "Add your SIP credentials there now. The file is ignored by Git."
else
  echo "Already present: runtime/baresip/accounts"
fi

echo "Setup complete. Start with: sh scripts/run.sh"
