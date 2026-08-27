#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
ACCOUNT="$ROOT/runtime/baresip/accounts"
EXAMPLE="$ROOT/runtime/baresip/accounts.example"

missing=0
for command in xcrun swift brew; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Fehlt: $command" >&2
    missing=1
  fi
done

if [ "$missing" -ne 0 ]; then
  echo "Installiere Xcode Command Line Tools und Homebrew, dann starte das Setup erneut." >&2
  exit 1
fi

for formula in baresip libre; do
  if ! brew --prefix "$formula" >/dev/null 2>&1; then
    echo "Fehlt: $formula (Installation: brew install $formula)" >&2
    missing=1
  fi
done

if [ "$missing" -ne 0 ]; then
  exit 1
fi

if [ ! -f "$ACCOUNT" ]; then
  cp "$EXAMPLE" "$ACCOUNT"
  echo "Angelegt: runtime/baresip/accounts"
  echo "Trage dort jetzt deine SIP-Zugangsdaten ein. Die Datei wird von Git ignoriert."
else
  echo "Vorhanden: runtime/baresip/accounts"
fi

echo "Setup vollständig. Start: sh scripts/run.sh"
