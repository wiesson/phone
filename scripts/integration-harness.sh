#!/bin/sh

integration_detect_host_ip() {
  detected=$(ipconfig getifaddr en0 2>/dev/null || true)
  if [ -z "$detected" ]; then
    detected=$(ifconfig 2>/dev/null | awk '$1 == "inet" && $2 != "127.0.0.1" {print $2; exit}')
  fi
  if [ -z "$detected" ]; then
    detected=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
  fi
  printf '%s\n' "$detected"
}

integration_file_size() {
  wc -c < "$1" | tr -d ' '
}

integration_contains() {
  grep -Eiq "$2" "$1" 2>/dev/null
}

integration_wait_for() {
  log=$1
  pattern=$2
  pid=$3
  seconds=$4
  elapsed=0
  while [ "$elapsed" -lt "$seconds" ]; do
    if integration_contains "$log" "$pattern"; then
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

integration_wait_for_after() {
  log=$1
  pattern=$2
  pid=$3
  seconds=$4
  offset=$5
  slice=$6
  elapsed=0
  while [ "$elapsed" -lt "$seconds" ]; do
    tail -c "+$((offset + 1))" "$log" > "$slice"
    if integration_contains "$slice" "$pattern"; then
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

integration_send_a() {
  printf '%s\n' "$1" >&3
}

integration_send_b() {
  printf '%s\n' "$1" >&4
}

integration_cleanup() {
  if [ -n "${A_PID:-}" ] && kill -0 "$A_PID" 2>/dev/null; then
    kill "$A_PID" 2>/dev/null || true
  fi
  if [ -n "${B_PID:-}" ] && kill -0 "$B_PID" 2>/dev/null; then
    kill "$B_PID" 2>/dev/null || true
  fi
  exec 3>&- 4>&- || true
  if [ -n "${TEST_DIR:-}" ]; then
    if [ "${PHONE_KEEP_INTEGRATION_TMP:-0}" = 1 ]; then
      echo "Integration artifacts: $TEST_DIR" >&2
    else
      case "$TEST_DIR" in
        "$TEST_TMP_ROOT"/phone-loopback.*) rm -rf -- "$TEST_DIR" ;;
      esac
    fi
  fi
}

integration_show_transcripts() {
  echo "baresip: ${BARESIP:-not selected}" >&2
  echo "scenario: ${SCENARIO:-not selected}" >&2
  if [ -n "${A_LOG:-}" ] && [ -f "$A_LOG" ]; then
    echo "--- A transcript ---" >&2
    sed -n '1,$p' "$A_LOG" >&2
  fi
  if [ -n "${B_LOG:-}" ] && [ -f "$B_LOG" ]; then
    echo "--- B transcript ---" >&2
    sed -n '1,$p' "$B_LOG" >&2
  fi
}

integration_fail() {
  echo "Loopback integration test failed: $1" >&2
  integration_show_transcripts
  exit 1
}

integration_skip() {
  echo "SKIP: $1"
  if [ "${PHONE_MATRIX_CHILD:-0}" = 1 ]; then
    exit 77
  fi
  exit 0
}

integration_require_module() {
  module=$1
  if [ ! -f "$MODULES/$module" ]; then
    integration_fail "required baresip module was not found: $MODULES/$module"
  fi
}

integration_require_optional_module() {
  module=$1
  capability=$2
  if [ ! -f "$MODULES/$module" ]; then
    integration_skip "$capability is unavailable because $MODULES/$module is missing"
  fi
}

integration_select_scenario() {
  SCENARIO=${PHONE_INTEGRATION_SCENARIO:-smoke}
  TRANSPORT=udp
  CODEC=PCMU
  DTMF_MODE=none
  MEDIAENC=none
  CALL_FLOW=establish
  CHECK_MUTE=no

  case "$SCENARIO" in
    smoke)
      DTMF_MODE=rfc2833
      CHECK_MUTE=yes
      ;;
    transport-udp) ;;
    transport-tcp) TRANSPORT=tcp ;;
    codec-pcma) CODEC=PCMA ;;
    codec-pcmu) CODEC=PCMU ;;
    dtmf-inband) DTMF_MODE=in-band ;;
    dtmf-rfc2833) DTMF_MODE=rfc2833 ;;
    media-none) ;;
    media-srtp) MEDIAENC=srtp ;;
    interruption-reject) CALL_FLOW=reject ;;
    interruption-cancel) CALL_FLOW=cancel ;;
    *) integration_fail "unknown scenario: $SCENARIO" ;;
  esac
}

integration_write_config() {
  directory=$1
  port=$2
  device=$3
  rtp_ports=$4
  extra_module=$5
  telev_pt=101
  if [ "$DTMF_MODE" = in-band ]; then
    telev_pt=0
  fi

  sed \
    -e "s|@PORT@|$port|g" \
    -e "s|@HOST_IP@|$HOST_IP|g" \
    -e "s|@DEVICE@|$device|g" \
    -e "s|@RTP_PORTS@|$rtp_ports|g" \
    -e "s|@MODULES@|$MODULES|g" \
    -e "s|@TRANSPORT@|$TRANSPORT|g" \
    -e "s|@TELEV_PT@|$telev_pt|g" \
    -e "s|@EXTRA_MODULE@|$extra_module|g" \
    > "$directory/config" <<'CONFIG'
sip_listen @HOST_IP@:@PORT@
sip_transports @TRANSPORT@
call_local_timeout 60
call_max_calls 1
call_hold_other_calls yes
call_accept no
audio_player aubridge,@DEVICE@
audio_source aubridge,@DEVICE@
audio_alert aubridge,@DEVICE@
audio_level no
ausrc_format s16
auplay_format s16
auenc_format s16
audec_format s16
audio_buffer 20-160
audio_telev_pt @TELEV_PT@
rtp_ports @RTP_PORTS@
module_path @MODULES@
module stdio.so
module g711.so
module auconv.so
module auresamp.so
module aubridge.so
@EXTRA_MODULE@
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

integration_account() {
  port=$1
  answer_mode=$2
  params="regint=0;answermode=$answer_mode;audio_codecs=$CODEC/8000/1"
  if [ "$DTMF_MODE" = in-band ]; then
    params="$params;autelev_pt=0"
  elif [ "$DTMF_MODE" = rfc2833 ]; then
    params="$params;autelev_pt=101;dtmfmode=rtpevent"
  fi
  if [ "$MEDIAENC" = srtp ]; then
    params="$params;mediaenc=srtp"
  fi
  printf '<sip:test@%s:%s;transport=%s>;%s' "$HOST_IP" "$port" "$TRANSPORT" "$params"
}

integration_wait_ready() {
  if ! integration_wait_for "$A_LOG" "baresip is ready" "$A_PID" 30; then
    if integration_contains "$A_LOG" "network init failed: Operation not permitted"; then
      integration_skip "the host sandbox forbids baresip network initialization (Operation not permitted)"
    fi
    integration_fail "instance A did not become ready"
  fi
  if ! integration_wait_for "$B_LOG" "baresip is ready" "$B_PID" 30; then
    if integration_contains "$B_LOG" "network init failed: Operation not permitted"; then
      integration_skip "the host sandbox forbids baresip network initialization (Operation not permitted)"
    fi
    integration_fail "instance B did not become ready"
  fi
}

integration_capture_a_window() {
  if integration_contains "$A_LOG" "Call established"; then
    awk '/Call established/ { active = 1 } active { print }' "$A_LOG" > "$A_WINDOW"
  else
    tail -c "+$((A_CALL_START + 1))" "$A_LOG" > "$A_WINDOW"
  fi
}

integration_assert_no_phantom_call() {
  integration_capture_a_window
  if integration_contains "$A_WINDOW" "Incoming call from"; then
    integration_fail "instance A reported a phantom incoming call in its active call window"
  fi
}

integration_assert_codec() {
  integration_wait_for "$A_LOG" "Set audio encoder: $CODEC 8000Hz" "$A_PID" 15 ||
    integration_fail "instance A did not negotiate the $CODEC encoder"
  integration_wait_for "$A_LOG" "Set audio decoder: $CODEC 8000Hz" "$A_PID" 15 ||
    integration_fail "instance A did not negotiate the $CODEC decoder"
  integration_wait_for "$B_LOG" "Set audio encoder: $CODEC 8000Hz" "$B_PID" 15 ||
    integration_fail "instance B did not negotiate the $CODEC encoder"
  integration_wait_for "$B_LOG" "Set audio decoder: $CODEC 8000Hz" "$B_PID" 15 ||
    integration_fail "instance B did not negotiate the $CODEC decoder"
}

integration_run_established_call() {
  A_CALL_START=$(integration_file_size "$A_LOG")
  integration_send_a "/dial sip:test@$HOST_IP:5089;transport=$TRANSPORT"
  integration_wait_for_after "$A_LOG" "Call established" "$A_PID" 45 "$A_CALL_START" "$A_SLICE" ||
    integration_fail "instance A did not establish the call"
  integration_wait_for "$B_LOG" "Call established" "$B_PID" 15 ||
    integration_fail "instance B did not establish the call"
  integration_assert_codec

  if [ "$MEDIAENC" = srtp ]; then
    integration_wait_for "$A_LOG" "srtp.*SRTP is Enabled" "$A_PID" 15 ||
      integration_fail "instance A did not enable SRTP"
    integration_wait_for "$B_LOG" "srtp.*SRTP is Enabled" "$B_PID" 15 ||
      integration_fail "instance B did not enable SRTP"
  fi

  if [ "$DTMF_MODE" != none ]; then
    B_DTMF_START=$(integration_file_size "$B_LOG")
    if [ "$DTMF_MODE" = in-band ]; then
      integration_send_a "/in_band_dtmf_send 2"
    else
      integration_send_a "/sndcode 2"
      integration_wait_for "$A_LOG" "send DTMF digit: '2'" "$A_PID" 15 ||
        integration_fail "instance A did not send RFC 2833 DTMF"
    fi
    integration_wait_for_after "$B_LOG" "received in-band DTMF event: '2'" "$B_PID" 15 "$B_DTMF_START" "$B_DTMF_SLICE" ||
      integration_fail "instance B did not report the received $DTMF_MODE DTMF event"
  fi

  if [ "$CHECK_MUTE" = yes ]; then
    integration_send_a "/mute"
    integration_wait_for "$A_LOG" "call muted" "$A_PID" 15 ||
      integration_fail "instance A did not mute the call"
    integration_send_a "/mute"
    integration_wait_for "$A_LOG" "call un-muted" "$A_PID" 15 ||
      integration_fail "instance A did not unmute the call"
  fi

  A_CLOSE_START=$(integration_file_size "$A_LOG")
  integration_send_a "/hangup"
  integration_wait_for_after "$A_LOG" "Call with .* terminated|session closed|call closed|terminate call" "$A_PID" 30 "$A_CLOSE_START" "$A_CLOSE_SLICE" ||
    integration_fail "instance A did not report call termination after hangup"
  integration_assert_no_phantom_call
}

integration_wait_for_ringing() {
  integration_wait_for "$B_LOG" "Incoming call from" "$B_PID" 30 ||
    integration_fail "instance B did not report the incoming ringing call"
  integration_wait_for_after "$A_LOG" "Call in-progress|SIP Progress: 180 .*Ringing" "$A_PID" 15 "$A_CALL_START" "$A_SLICE" ||
    integration_fail "instance A did not report ringing progress"
}

integration_assert_interrupted() {
  integration_wait_for_after "$A_LOG" "Call with .* terminated|session closed|call closed|terminate call" "$A_PID" 30 "$A_CALL_START" "$A_SLICE" ||
    integration_fail "instance A did not report the interrupted call termination"
  if integration_contains "$A_SLICE" "Call established" || integration_contains "$B_LOG" "Call established"; then
    integration_fail "the interrupted call unexpectedly established"
  fi
  integration_assert_no_phantom_call
}

integration_run_interruption() {
  A_CALL_START=$(integration_file_size "$A_LOG")
  integration_send_a "/dial sip:test@$HOST_IP:5089;transport=$TRANSPORT"
  integration_wait_for_ringing
  if [ "$CALL_FLOW" = reject ]; then
    integration_send_b "/hangup"
  else
    integration_send_a "/hangup"
  fi
  integration_assert_interrupted
}

integration_stop_instances() {
  integration_send_a "/quit"
  integration_send_b "/quit"
  elapsed=0
  while { kill -0 "$A_PID" 2>/dev/null || kill -0 "$B_PID" 2>/dev/null; } && [ "$elapsed" -lt 15 ]; do
    sleep 1
    elapsed=$((elapsed + 1))
  done
  if kill -0 "$A_PID" 2>/dev/null || kill -0 "$B_PID" 2>/dev/null; then
    integration_fail "baresip instances did not quit cleanly"
  fi
  wait "$A_PID" 2>/dev/null || true
  wait "$B_PID" 2>/dev/null || true
  A_PID=
  B_PID=
}

run_integration_scenario() {
  integration_select_scenario

  ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
  BUNDLED_BARESIP="$ROOT/dist/Phone.app/Contents/Helpers/baresip"
  BUNDLED_MODULES="$ROOT/dist/Phone.app/Contents/Resources/baresip/modules"
  if [ -n "${BARESIP_BIN:-}" ]; then
    BARESIP=$BARESIP_BIN
  elif [ -x "$BUNDLED_BARESIP" ]; then
    BARESIP=$BUNDLED_BARESIP
  elif [ -x /opt/homebrew/bin/baresip ]; then
    BARESIP=/opt/homebrew/bin/baresip
  elif [ -x /usr/local/bin/baresip ]; then
    BARESIP=/usr/local/bin/baresip
  else
    integration_fail "baresip was not found; run sh scripts/build-app.sh or brew install baresip"
  fi

  if [ "$BARESIP" = "$BUNDLED_BARESIP" ]; then
    MODULES=$BUNDLED_MODULES
  else
    BARESIP_PREFIX=$(CDPATH= cd -- "$(dirname "$BARESIP")/.." && pwd)
    MODULES="$BARESIP_PREFIX/lib/baresip/modules"
  fi

  for module in stdio.so menu.so g711.so auconv.so auresamp.so aubridge.so; do
    integration_require_module "$module"
  done

  EXTRA_MODULE=
  if [ "$DTMF_MODE" = in-band ]; then
    integration_require_optional_module in_band_dtmf.so "in-band DTMF"
    EXTRA_MODULE="module in_band_dtmf.so"
  fi
  if [ "$MEDIAENC" = srtp ]; then
    integration_require_optional_module srtp.so "SRTP"
    EXTRA_MODULE="module srtp.so"
  fi

  HOST_IP=${PHONE_TEST_IP:-$(integration_detect_host_ip)}
  if [ -z "$HOST_IP" ]; then
    integration_skip "no usable non-loopback IPv4 host address was detected; set PHONE_TEST_IP"
  fi

  TEST_TMP_ROOT=${TMPDIR:-/tmp}
  TEST_DIR=$(mktemp -d "$TEST_TMP_ROOT/phone-loopback.$SCENARIO.XXXXXX")
  A_DIR="$TEST_DIR/a"
  B_DIR="$TEST_DIR/b"
  A_LOG="$TEST_DIR/a.log"
  B_LOG="$TEST_DIR/b.log"
  A_FIFO="$TEST_DIR/a.stdin"
  B_FIFO="$TEST_DIR/b.stdin"
  A_WINDOW="$TEST_DIR/a-call-window.log"
  A_SLICE="$TEST_DIR/a-slice.log"
  A_CLOSE_SLICE="$TEST_DIR/a-close.log"
  B_DTMF_SLICE="$TEST_DIR/b-dtmf.log"
  A_PID=
  B_PID=
  A_CALL_START=0
  trap integration_cleanup EXIT HUP INT TERM

  mkdir -p "$A_DIR" "$B_DIR"
  mkfifo "$A_FIFO" "$B_FIFO"
  exec 3<>"$A_FIFO"
  exec 4<>"$B_FIFO"

  integration_write_config "$A_DIR" 5088 caller 40000-40049 "$EXTRA_MODULE"
  integration_write_config "$B_DIR" 5089 callee 40050-40099 "$EXTRA_MODULE"

  "$BARESIP" -f "$B_DIR" -4 -c -v < "$B_FIFO" > "$B_LOG" 2>&1 &
  B_PID=$!
  "$BARESIP" -f "$A_DIR" -4 -c -v < "$A_FIFO" > "$A_LOG" 2>&1 &
  A_PID=$!

  integration_wait_ready

  answer_mode=auto
  if [ "$CALL_FLOW" != establish ]; then
    answer_mode=manual
  fi
  integration_send_a "/uanew $(integration_account 5088 manual)"
  integration_send_b "/uanew $(integration_account 5089 "$answer_mode")"
  integration_wait_for "$A_LOG" "Creating UA for.*:5088" "$A_PID" 15 ||
    integration_fail "instance A did not create its registrar-less UA"
  integration_wait_for "$B_LOG" "Creating UA for.*:5089" "$B_PID" 15 ||
    integration_fail "instance B did not create its registrar-less UA"

  if [ "$DTMF_MODE" != none ] && {
       integration_contains "$A_LOG" "unknown .*audio_telev|invalid .*autelev|invalid dtmfmode" ||
       integration_contains "$B_LOG" "unknown .*audio_telev|invalid .*autelev|invalid dtmfmode";
     }; then
    integration_skip "baresip rejected the telephone-event/DTMF option required by $SCENARIO"
  fi
  if [ "$MEDIAENC" = srtp ] && {
       integration_contains "$A_LOG" "srtp\.so.*(failed|not found)|mediaenc.*(not found|not supported)" ||
       integration_contains "$B_LOG" "srtp\.so.*(failed|not found)|mediaenc.*(not found|not supported)";
     }; then
    integration_skip "baresip could not load or configure its SRTP media-encryption capability"
  fi

  if [ "$CALL_FLOW" = establish ]; then
    integration_run_established_call
  else
    integration_run_interruption
  fi

  integration_stop_instances
  echo "Loopback integration test passed: $SCENARIO with $BARESIP"
}
