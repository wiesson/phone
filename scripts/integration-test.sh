#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
BUNDLED_BARESIP="$ROOT/dist/Phone.app/Contents/Helpers/baresip"
BUNDLED_MODULES="$ROOT/dist/Phone.app/Contents/Resources/baresip/modules"

if [ -n "${BARESIP_BIN:-}" ]; then
  BARESIP=$BARESIP_BIN
elif [ -x "$BUNDLED_BARESIP" ]; then
  BARESIP=$BUNDLED_BARESIP
elif [ -x /opt/homebrew/bin/baresip ]; then
  BARESIP=/opt/homebrew/bin/baresip
else
  echo "baresip was not found. Run sh scripts/build-app.sh or brew install baresip." >&2
  exit 1
fi

if [ "$BARESIP" = "$BUNDLED_BARESIP" ]; then
  MODULES=$BUNDLED_MODULES
else
  BARESIP_PREFIX=$(CDPATH= cd -- "$(dirname "$BARESIP")/.." && pwd)
  MODULES="$BARESIP_PREFIX/lib/baresip/modules"
fi

for module in stdio.so menu.so g711.so auconv.so auresamp.so aubridge.so; do
  if [ ! -f "$MODULES/$module" ]; then
    echo "Required baresip module was not found: $MODULES/$module" >&2
    exit 1
  fi
done

TEST_TMP_ROOT=${TMPDIR:-/tmp}
TEST_DIR=$(mktemp -d "$TEST_TMP_ROOT/phone-loopback.XXXXXX")
A_DIR="$TEST_DIR/a"
B_DIR="$TEST_DIR/b"
A_LOG="$TEST_DIR/a.log"
B_LOG="$TEST_DIR/b.log"
A_FIFO="$TEST_DIR/a.stdin"
B_FIFO="$TEST_DIR/b.stdin"
A_WINDOW="$TEST_DIR/a-established-to-hangup.log"
A_DTMF_LOG="$TEST_DIR/a-after-sndcode.log"
A_CLOSE_LOG="$TEST_DIR/a-after-hangup.log"
EXPECTED="$TEST_DIR/expected.txt"
OBSERVED="$TEST_DIR/observed.txt"
A_DTMF_START=
A_CLOSE_START=
A_WINDOW_CAPTURED=no
A_PID=
B_PID=

cleanup() {
  if [ -n "$A_PID" ] && kill -0 "$A_PID" 2>/dev/null; then
    kill "$A_PID" 2>/dev/null || true
  fi
  if [ -n "$B_PID" ] && kill -0 "$B_PID" 2>/dev/null; then
    kill "$B_PID" 2>/dev/null || true
  fi
  exec 3>&- 4>&- || true
  if [ "${PHONE_KEEP_INTEGRATION_TMP:-0}" = 1 ]; then
    echo "Integration artifacts: $TEST_DIR" >&2
  else
    case "$TEST_DIR" in
      "$TEST_TMP_ROOT"/phone-loopback.*) rm -rf -- "$TEST_DIR" ;;
    esac
  fi
}
trap cleanup EXIT HUP INT TERM

HOST_IP=${PHONE_TEST_IP:-$(ipconfig getifaddr en0 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')}
if [ -z "$HOST_IP" ]; then
  echo "No usable IPv4 host address found; set PHONE_TEST_IP" >&2
  exit 1
fi

mkdir -p "$A_DIR" "$B_DIR"
mkfifo "$A_FIFO" "$B_FIFO"
exec 3<>"$A_FIFO"
exec 4<>"$B_FIFO"

write_config() {
  directory=$1
  port=$2
  accept=$3
  device=$4
  rtp_ports=$5
  sed \
    -e "s|@PORT@|$port|g" \
    -e "s|@HOST_IP@|$HOST_IP|g" \
    -e "s|@ACCEPT@|$accept|g" \
    -e "s|@DEVICE@|$device|g" \
    -e "s|@RTP_PORTS@|$rtp_ports|g" \
    -e "s|@MODULES@|$MODULES|g" \
    > "$directory/config" <<'CONFIG'
sip_listen @HOST_IP@:@PORT@
sip_transports udp
call_local_timeout 60
call_max_calls 1
call_hold_other_calls yes
call_accept @ACCEPT@
audio_player aubridge,@DEVICE@
audio_source aubridge,@DEVICE@
audio_alert aubridge,@DEVICE@
audio_level no
ausrc_format s16
auplay_format s16
auenc_format s16
audec_format s16
audio_buffer 20-160
audio_telev_pt 101
rtp_ports @RTP_PORTS@
module_path @MODULES@
module stdio.so
module g711.so
module auconv.so
module auresamp.so
module aubridge.so
module_app menu.so
ring_aufile none
hangup_aufile none
callwaiting_aufile none
ringback_aufile none
notfound_aufile none
busy_aufile none
error_aufile none
sip_autoanswer_aufile none
CONFIG
  : > "$directory/accounts"
}

write_config "$A_DIR" 5088 no caller 40000-40049
write_config "$B_DIR" 5089 yes callee 40050-40099

"$BARESIP" -f "$B_DIR" -4 -c -v < "$B_FIFO" > "$B_LOG" 2>&1 &
B_PID=$!
"$BARESIP" -f "$A_DIR" -4 -c -v < "$A_FIFO" > "$A_LOG" 2>&1 &
A_PID=$!

wait_for() {
  log=$1
  pattern=$2
  pid=$3
  seconds=$4
  elapsed=0
  while [ "$elapsed" -lt "$seconds" ]; do
    if grep -Eiq "$pattern" "$log" 2>/dev/null; then
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  return 1
}

wait_for_after() {
  log=$1
  pattern=$2
  pid=$3
  seconds=$4
  offset=$5
  slice=$6
  elapsed=0
  while [ "$elapsed" -lt "$seconds" ]; do
    tail -c "+$((offset + 1))" "$log" > "$slice"
    if grep -Eiq "$pattern" "$slice" 2>/dev/null; then
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  return 1
}

send_a() {
  printf '%s\n' "$1" >&3
}

send_b() {
  printf '%s\n' "$1" >&4
}

contains() {
  file=$1
  pattern=$2
  if grep -Eiq "$pattern" "$file" 2>/dev/null; then
    printf 'yes'
  else
    printf 'no'
  fi
}

expectations_match() {
  if [ "$A_WINDOW_CAPTURED" = no ]; then
    awk '/Call established/ { active = 1 } active { print }' "$A_LOG" > "$A_WINDOW"
  fi
  if [ -n "$A_DTMF_START" ]; then
    tail -c "+$((A_DTMF_START + 1))" "$A_LOG" > "$A_DTMF_LOG"
  else
    : > "$A_DTMF_LOG"
  fi
  if [ -n "$A_CLOSE_START" ]; then
    tail -c "+$((A_CLOSE_START + 1))" "$A_LOG" > "$A_CLOSE_LOG"
  else
    : > "$A_CLOSE_LOG"
  fi
  cat > "$EXPECTED" <<'EXPECTATIONS'
A established: yes
B established: yes
A DTMF after established: yes
A closed after hangup: yes
A unexpected incoming after established: no
EXPECTATIONS
  {
    printf 'A established: %s\n' "$(contains "$A_LOG" "Call established")"
    printf 'B established: %s\n' "$(contains "$B_LOG" "Call established")"
    printf 'A DTMF after established: %s\n' "$(contains "$A_DTMF_LOG" "send DTMF digit|telephone-event")"
    printf 'A closed after hangup: %s\n' "$(contains "$A_CLOSE_LOG" "call closed|session closed|Call with .* terminated|terminate call")"
    printf 'A unexpected incoming after established: %s\n' "$(contains "$A_WINDOW" "Incoming call from")"
  } > "$OBSERVED"
  diff -u "$EXPECTED" "$OBSERVED"
}

show_failure() {
  reason=$1
  echo "Loopback integration test failed: $reason" >&2
  echo "baresip: $BARESIP" >&2
  expectations_match >&2 || true
  echo "--- A transcript ---" >&2
  sed -n '1,$p' "$A_LOG" >&2
  echo "--- B transcript ---" >&2
  sed -n '1,$p' "$B_LOG" >&2
  exit 1
}

wait_for "$A_LOG" "baresip is ready" "$A_PID" 30 || show_failure "instance A did not become ready"
wait_for "$B_LOG" "baresip is ready" "$B_PID" 30 || show_failure "instance B did not become ready"

send_a "/uanew <sip:test@$HOST_IP:5088;transport=udp>;regint=0"
send_b "/uanew <sip:test@$HOST_IP:5089;transport=udp>;regint=0;answermode=auto"
wait_for "$A_LOG" "Creating UA for.*:5088" "$A_PID" 15 || show_failure "instance A did not create its registrar-less UA"
wait_for "$B_LOG" "Creating UA for.*:5089" "$B_PID" 15 || show_failure "instance B did not create its registrar-less UA"

send_a "/dial sip:test@$HOST_IP:5089;transport=udp"
wait_for "$A_LOG" "Call established" "$A_PID" 45 || show_failure "instance A did not establish the call"
wait_for "$B_LOG" "Call established" "$B_PID" 15 || show_failure "instance B did not establish the call"

A_DTMF_START=$(wc -c < "$A_LOG" | tr -d ' ')
send_a "/sndcode 2"
wait_for_after "$A_LOG" "send DTMF digit|telephone-event" "$A_PID" 15 "$A_DTMF_START" "$A_DTMF_LOG" || show_failure "instance A did not report sending DTMF"
send_a "/mute"
wait_for "$A_LOG" "call muted" "$A_PID" 15 || show_failure "instance A did not mute the call"
send_a "/mute"
wait_for "$A_LOG" "call un-muted" "$A_PID" 15 || show_failure "instance A did not unmute the call"
awk '/Call established/ { active = 1 } active { print }' "$A_LOG" > "$A_WINDOW"
A_WINDOW_CAPTURED=yes
A_CLOSE_START=$(wc -c < "$A_LOG" | tr -d ' ')
send_a "/hangup"
wait_for_after "$A_LOG" "call closed|session closed|Call with .* terminated|terminate call" "$A_PID" 30 "$A_CLOSE_START" "$A_CLOSE_LOG" || show_failure "instance A did not close the call after hangup"

send_a "/quit"
send_b "/quit"

elapsed=0
while { kill -0 "$A_PID" 2>/dev/null || kill -0 "$B_PID" 2>/dev/null; } && [ "$elapsed" -lt 15 ]; do
  sleep 1
  elapsed=$((elapsed + 1))
done
if kill -0 "$A_PID" 2>/dev/null || kill -0 "$B_PID" 2>/dev/null; then
  show_failure "baresip instances did not quit cleanly"
fi

if ! expectations_match; then
  show_failure "transcript expectations were not met"
fi

echo "Loopback integration test passed with $BARESIP"
