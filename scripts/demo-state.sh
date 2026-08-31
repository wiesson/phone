#!/bin/sh
# Save, wipe and restore the Phone configuration around a demo recording.
#
# accounts.json holds the SIP lines AND the saved assistant profiles, so a
# demo that starts from nothing has to move it out of the way first. The SIP
# passwords live in the Keychain, not in this file, so a restore brings the
# lines back registered — nothing here touches the Keychain.
set -eu

STATE_DIR="$HOME/Library/Application Support/Phone"
STATE="$STATE_DIR/accounts.json"
BACKUP_DIR="$STATE_DIR/demo-backups"

usage() {
  cat <<'EOF'
Usage: sh scripts/demo-state.sh <command> [argument]

  status            Show the lines and profiles currently configured.
  backup [label]    Copy accounts.json to a new timestamped backup.
  list              List the backups, newest first.
  reset             Back up, then leave Phone with no lines and no profiles.
  restore [name]    Restore a backup, or the newest one when none is named.

reset and restore require Phone to be closed: a running app writes
accounts.json from memory and would undo the change.
EOF
}

# Reads accounts.json and prints what a human needs to recognise it again.
# Kept free of passwords and tokens: this output ends up in terminal
# recordings.
describe() {
  python3 - "$1" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as handle:
        state = json.load(handle)
except FileNotFoundError:
    print("  (no accounts.json — Phone starts empty)")
    sys.exit(0)
except json.JSONDecodeError as error:
    print(f"  ! not valid JSON: {error}")
    sys.exit(1)

accounts = state.get("accounts") or []
profiles = state.get("savedProfiles") or []
print(f"  {len(accounts)} line(s), {len(profiles)} saved profile(s)")
for account in accounts:
    label = account.get("label") or account.get("username") or "?"
    mark = " " if account.get("isEnabled") else "-"
    print(f"   {mark} line    {label}")
for profile in profiles:
    print(f"     profile {profile.get('name') or '?'}")
PY
}

require_closed() {
  if pgrep -f "Phone.app/Contents/MacOS/Phone" >/dev/null 2>&1; then
    echo "Phone is running. Quit it first, then run this again." >&2
    echo "  osascript -e 'quit app \"Phone\"'" >&2
    exit 1
  fi
}

# Every backup is a new file. Overwriting one would be the single way this
# script could lose the profiles it exists to protect.
make_backup() {
  label=${1:-}
  [ -f "$STATE" ] || { echo "Nothing to back up: $STATE does not exist." >&2; return 1; }
  describe "$STATE" >/dev/null || { echo "Refusing to back up a broken accounts.json." >&2; return 1; }
  mkdir -p "$BACKUP_DIR"
  suffix=$(printf '%s' "${label:+-$label}" | tr -c 'A-Za-z0-9-' '-')
  target="$BACKUP_DIR/accounts-$(date +%Y%m%d-%H%M%S)$suffix.json"
  [ -e "$target" ] && { echo "Backup $target already exists." >&2; return 1; }
  cp "$STATE" "$target"
  echo "Backed up to $target"
  describe "$target"
}

# Backups newest first, one full path per line.
list_backups() {
  [ -d "$BACKUP_DIR" ] || return 0
  # -t sorts by modification time; the timestamped names sort the same way.
  find "$BACKUP_DIR" -maxdepth 1 -name 'accounts-*.json' -print0 2>/dev/null \
    | xargs -0 /bin/ls -t 2>/dev/null
}

newest_backup() {
  list_backups | head -1
}

command=${1:-}
case "$command" in
  status)
    echo "$STATE"
    describe "$STATE"
    ;;

  backup)
    make_backup "${2:-}"
    ;;

  list)
    if [ ! -d "$BACKUP_DIR" ]; then
      echo "No backups yet."
      exit 0
    fi
    # A while-read loop, not a for over $(...): the backup directory sits
    # under "Application Support", and word splitting would tear the path in
    # half at the space.
    list_backups | while IFS= read -r file; do
      [ -n "$file" ] || continue
      echo "$(basename "$file")"
      describe "$file"
    done
    ;;

  reset)
    require_closed
    if [ -f "$STATE" ]; then
      make_backup "before-reset"
    else
      echo "$STATE does not exist — Phone is already empty."
      exit 0
    fi
    rm -f "$STATE"
    echo
    echo "Phone now starts with no lines and no profiles."
    echo "Restore with: sh scripts/demo-state.sh restore"
    ;;

  restore)
    require_closed
    name=${2:-}
    if [ -n "$name" ]; then
      case "$name" in
        /*) source=$name ;;
        *)  source="$BACKUP_DIR/$name" ;;
      esac
    else
      source=$(newest_backup) || true
    fi
    [ -n "${source:-}" ] && [ -f "$source" ] || {
      echo "No backup to restore${name:+ named $name}." >&2
      echo "Run: sh scripts/demo-state.sh list" >&2
      exit 1
    }
    describe "$source" >/dev/null || { echo "Refusing to restore a broken backup." >&2; exit 1; }
    # The current file may itself be worth keeping — a profile written during
    # the demo is real work too.
    [ -f "$STATE" ] && make_backup "before-restore"
    cp "$source" "$STATE"
    echo "Restored $(basename "$source")"
    describe "$STATE"
    ;;

  ''|-h|--help|help)
    usage
    ;;

  *)
    echo "Unknown command: $command" >&2
    echo >&2
    usage >&2
    exit 1
    ;;
esac
