#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
APP="$ROOT/dist/Phone.app"
sh "$ROOT/scripts/build-app.sh"
open "$APP"
echo "Configuration: $HOME/Library/Application Support/Phone/baresip"
