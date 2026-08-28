#!/bin/sh
# Live end-to-end test over the real SIP provider: registers two of your own
# numbers as headless baresip instances and lets one call the other.
#
#   PHONE_E2E_CALLER=+49... PHONE_E2E_CALLEE=+49... sh scripts/e2e-live-test.sh
#
# Both numbers must belong to accounts of your line (line-based auth, no
# password is written to disk). The callee auto-answers; the test asserts
# establishment on both sides, in-band DTMF delivery, mute/unmute, and a clean
# hangup. Uses the bundled baresip and hardware-free aubridge audio, so it can
# run while the app itself stays registered with a third number.
set -eu

CALLER=${PHONE_E2E_CALLER:?set PHONE_E2E_CALLER to the calling number}
CALLEE=${PHONE_E2E_CALLEE:?set PHONE_E2E_CALLEE to the called number}
DOMAIN=${PHONE_E2E_DOMAIN:-tel.t-online.de}
OUTBOUND=${PHONE_E2E_OUTBOUND:-sip:tel.t-online.de}
STUN=${PHONE_E2E_STUN:-stun:stun.t-online.de}
MEDIAENC=${PHONE_E2E_MEDIAENC:-srtp-mand}

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
BARESIP="$ROOT/dist/Phone.app/Contents/Helpers/baresip"
MODULES="$ROOT/dist/Phone.app/Contents/Resources/baresip/modules"
[ -x "$BARESIP" ] || { echo "Build the app first: sh scripts/build-app.sh" >&2; exit 1; }

BASE_CONFIG="$HOME/Library/Application Support/Phone/baresip/config"
[ -f "$BASE_CONFIG" ] || { echo "No baresip config at $BASE_CONFIG" >&2; exit 1; }

DIR=$(mktemp -d "${TMPDIR:-/tmp}/phone-e2e.XXXXXX")
A_PID=""
B_PID=""
cleanup() {
  [ -n "$A_PID" ] && kill "$A_PID" 2>/dev/null || true
  [ -n "$B_PID" ] && kill "$B_PID" 2>/dev/null || true
  sleep 1
  [ -n "$A_PID" ] && kill -9 "$A_PID" 2>/dev/null || true
  [ -n "$B_PID" ] && kill -9 "$B_PID" 2>/dev/null || true
  rm -rf "$DIR"
}
trap cleanup EXIT HUP INT TERM
umask 077

write_instance() {
  side=$1
  number=$2
  extra=$3
  rtp=$4
  mkdir -p "$DIR/$side"
  grep -vE '^module.*phone_tap|^audio_(player|source|alert)|^sip_trace|^module_path|^rtp_ports|^#' "$BASE_CONFIG" > "$DIR/$side/config"
  {
    echo "module_path		$MODULES"
    echo "module			aubridge.so"
    echo "module			in_band_dtmf.so"
    echo "audio_player		aubridge,$side"
    echo "audio_source		aubridge,$side"
    echo "audio_alert		aubridge,$side"
    echo "rtp_ports		$rtp"
  } >> "$DIR/$side/config"
  printf '<sip:%s@%s>;regint=300;outbound="%s";stunserver=%s;mediaenc=%s%s\n' \
    "$number" "$DOMAIN" "$OUTBOUND" "$STUN" "$MEDIAENC" "$extra" > "$DIR/$side/accounts"
}

wait_for() {
  file=$1; pattern=$2; seconds=$3
  i=0
  while [ "$i" -lt "$seconds" ]; do
    tr '\r' '\n' < "$file" | grep -Eq "$pattern" && return 0
    i=$((i + 1)); sleep 1
  done
  return 1
}

fail() {
  echo "E2E FAILED: $1" >&2
  echo "--- caller log ---" >&2; tr '\r' '\n' < "$DIR/a.log" | grep -v 'bit/s' | tail -30 >&2
  echo "--- callee log ---" >&2; tr '\r' '\n' < "$DIR/b.log" | grep -v 'bit/s' | tail -30 >&2
  exit 1
}

write_instance b "$CALLEE" ";answermode=auto" 41050-41099
write_instance a "$CALLER" "" 41000-41049

"$BARESIP" -f "$DIR/b" > "$DIR/b.log" 2>&1 & B_PID=$!
wait_for "$DIR/b.log" "registered successfully|200 OK \(\) \[1 binding\]" 25 || fail "callee did not register"

mkfifo "$DIR/a.fifo"
exec 7<>"$DIR/a.fifo"
"$BARESIP" -f "$DIR/a" < "$DIR/a.fifo" > "$DIR/a.log" 2>&1 & A_PID=$!
wait_for "$DIR/a.log" "registered successfully|200 OK \(\) \[1 binding\]" 25 || fail "caller did not register"

printf '/dial %s\n' "$CALLEE" >&7
if ! wait_for "$DIR/a.log" "Call established" 30; then
  printf '/dial %s\n' "$CALLEE" >&7
  wait_for "$DIR/a.log" "Call established" 30 || fail "call was not established (even after retry)"
fi
wait_for "$DIR/b.log" "Call established" 10 || fail "callee did not report establishment"

printf '/sndcode 7\n' >&7
wait_for "$DIR/b.log" "DTMF event: '7'" 15 || fail "callee did not receive DTMF"
printf '/mute\n' >&7
wait_for "$DIR/a.log" "call muted" 10 || fail "mute did not register"
printf '/mute\n' >&7
wait_for "$DIR/a.log" "call un-muted" 10 || fail "unmute did not register"
printf '/hangup\n' >&7
wait_for "$DIR/a.log" "terminated [(]duration" 15 || fail "caller did not terminate cleanly"
wait_for "$DIR/b.log" "terminated [(]duration" 10 || fail "callee did not see the termination"

printf '/quit\n' >&7
echo "E2E live test passed: $CALLER -> $CALLEE (established, DTMF, mute, hangup)"
