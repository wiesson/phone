#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
MATRIX_TMP_ROOT=${TMPDIR:-/tmp}
MATRIX_DIR=$(mktemp -d "$MATRIX_TMP_ROOT/phone-integration-matrix.XXXXXX")
RESULTS="$MATRIX_DIR/results.tsv"
: > "$RESULTS"
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

matrix_cleanup() {
  case "$MATRIX_DIR" in
    "$MATRIX_TMP_ROOT"/phone-integration-matrix.*) rm -rf -- "$MATRIX_DIR" ;;
  esac
}
trap matrix_cleanup EXIT HUP INT TERM

run_case() {
  scenario=$1
  transport=$2
  codec=$3
  dtmf=$4
  mediaenc=$5
  output="$MATRIX_DIR/$scenario.log"
  status=0
  PHONE_MATRIX_CHILD=1 PHONE_INTEGRATION_SCENARIO="$scenario" \
    sh "$SCRIPT_DIR/integration-test.sh" > "$output" 2>&1 || status=$?

  reason=
  if [ "$status" -eq 0 ]; then
    result=PASS
    PASS_COUNT=$((PASS_COUNT + 1))
  elif [ "$status" -eq 77 ]; then
    result=SKIP
    reason=$(sed -n 's/^SKIP: //p' "$output" | tail -n 1)
    if [ -z "$reason" ]; then
      reason="scenario reported exit 77 without a reason"
    fi
    SKIP_COUNT=$((SKIP_COUNT + 1))
  else
    result=FAIL
    reason="integration-test.sh exited $status"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$scenario" "$transport" "$codec" "$dtmf" "$mediaenc" "$result" "$reason" >> "$RESULTS"
  printf '%-24s %s' "$scenario" "$result"
  if [ -n "$reason" ]; then
    printf ' — %s' "$reason"
  fi
  printf '\n'

  if [ "$result" = FAIL ]; then
    sed -n '1,$p' "$output" >&2
  fi
}

run_case transport-udp udp PCMU n/a none
run_case transport-tcp tcp PCMU n/a none
run_case codec-pcma udp PCMA n/a none
run_case codec-pcmu udp PCMU n/a none
run_case dtmf-inband udp PCMU in-band none
run_case dtmf-rfc2833 udp PCMU rfc2833 none
run_case media-none udp PCMU n/a none
run_case media-srtp udp PCMU n/a srtp
run_case interruption-reject udp PCMU n/a none
run_case interruption-cancel udp PCMU n/a none

printf '\n%-24s %-9s %-7s %-9s %-9s %-6s %s\n' \
  "Scenario" "Transport" "Codec" "DTMF" "Mediaenc" "Result" "Skip/failure reason"
printf '%-24s %-9s %-7s %-9s %-9s %-6s %s\n' \
  "------------------------" "---------" "-------" "---------" "---------" "------" "-------------------"
while IFS="$(printf '\t')" read -r scenario transport codec dtmf mediaenc result reason; do
  printf '%-24s %-9s %-7s %-9s %-9s %-6s %s\n' \
    "$scenario" "$transport" "$codec" "$dtmf" "$mediaenc" "$result" "$reason"
done < "$RESULTS"
printf '\nMatrix summary: %s passed, %s failed, %s skipped\n' "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"

if [ "$FAIL_COUNT" -ne 0 ]; then
  exit 1
fi
