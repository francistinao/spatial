#!/bin/bash
# Three-pane log capture for the "HAL callbacks fire but every peak is 0.0000" debug session.
#
# Usage:
#   Drivers/SpatialSpeaker/debug-capture-logs.sh                # default: 60 s
#   Drivers/SpatialSpeaker/debug-capture-logs.sh 120            # 120 s window
#   OUT_DIR=/tmp/spatial-debug Drivers/SpatialSpeaker/debug-capture-logs.sh
#
# What it does:
#   - Streams three independent log predicates to disk in parallel for DURATION seconds.
#   - Pane A: driver subsystem (com.spatial.app.driver.speaker) — every os_log_error from the
#     SpatialSpeaker plug-in. This is the source of truth for AddDeviceClient / StartIO /
#     WillDoIOOperation / BeginIO / DoIO / WriteMix / ReadInput.
#   - Pane B: coreaudiod + AUHAL — every internal CoreAudio log. This is where the
#     `throwing -10877` lines live and where AudioDeviceStart / FormatNotSupported live.
#   - Pane C: Spatial app subsystem (com.spatial.app) — every Swift-side capture log.
#
# After capture:
#   - Open all three files side by side (e.g. `tail -F` in three panes) and grep for
#     "StartIO[diag-" to see whether coreaudiod ever issued StartIO on the capture client.
#   - If StartIO never appears, AUHAL accepted CurrentDevice + Initialize but never wired the
#     IOProc through to the driver — that is the failure we are debugging.

set -euo pipefail

DURATION="${1:-60}"
OUT_DIR="${OUT_DIR:-$(pwd)/debug-logs/$(date +%Y%m%d-%H%M%S)}"

mkdir -p "$OUT_DIR"

DRIVER_LOG="$OUT_DIR/driver.log"
COREAUDIO_LOG="$OUT_DIR/coreaudio.log"
APP_LOG="$OUT_DIR/app.log"

DRIVER_PRED='subsystem == "com.spatial.app.driver.speaker"'
COREAUDIO_PRED='process == "coreaudiod" OR subsystem == "com.apple.audio.AUHAL" OR subsystem == "com.apple.coreaudio" OR subsystem BEGINSWITH "com.apple.audio"'
APP_PRED='subsystem == "com.spatial.app"'

echo "Capturing ${DURATION}s of logs into $OUT_DIR"
echo "  Pane A driver:    $DRIVER_LOG"
echo "  Pane B coreaudio: $COREAUDIO_LOG"
echo "  Pane C app:       $APP_LOG"
echo
echo "Now in Spatial: route Spotify -> Spatial Speaker, press Start once, let it run."
echo

log stream --info --debug --style compact --predicate "$DRIVER_PRED" \
  > "$DRIVER_LOG" 2>&1 &
DRIVER_PID=$!

log stream --info --debug --style compact --predicate "$COREAUDIO_PRED" \
  > "$COREAUDIO_LOG" 2>&1 &
COREAUDIO_PID=$!

log stream --info --debug --style compact --predicate "$APP_PRED" \
  > "$APP_LOG" 2>&1 &
APP_PID=$!

cleanup() {
  kill "$DRIVER_PID" "$COREAUDIO_PID" "$APP_PID" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

sleep "$DURATION"
cleanup

echo
echo "Capture complete. Quick summary:"
echo

# macOS grep -c exits 1 when count is 0; `|| echo 0` then appends a second line and breaks `[ -eq ]`.
count_matches() { grep -c -- "$1" "$2" 2>/dev/null || true; }

driver_addclient_count=$(count_matches 'AddDeviceClient' "$DRIVER_LOG"); driver_addclient_count=${driver_addclient_count:-0}
driver_startio_count=$(count_matches 'StartIO\[' "$DRIVER_LOG"); driver_startio_count=${driver_startio_count:-0}
driver_willdo_count=$(count_matches 'WillDoIOOperation\[' "$DRIVER_LOG"); driver_willdo_count=${driver_willdo_count:-0}
driver_doio_count=$(count_matches 'DoIO entry\[' "$DRIVER_LOG"); driver_doio_count=${driver_doio_count:-0}
driver_readinput_count=$(count_matches 'DIAG ReadInput' "$DRIVER_LOG"); driver_readinput_count=${driver_readinput_count:-0}
driver_writemix_count=$(count_matches 'WriteMix n=' "$DRIVER_LOG"); driver_writemix_count=${driver_writemix_count:-0}

echo "Driver subsystem counts:"
echo "  AddDeviceClient:     $driver_addclient_count"
echo "  StartIO:             $driver_startio_count"
echo "  WillDoIOOperation:   $driver_willdo_count"
echo "  DoIO entry:          $driver_doio_count"
echo "  DIAG ReadInput:      $driver_readinput_count"
echo "  WriteMix:            $driver_writemix_count"
echo

ca_format_err=$(count_matches '-10877\|FormatNotSupported' "$COREAUDIO_LOG"); ca_format_err=${ca_format_err:-0}
ca_audio_dev_start=$(count_matches 'AudioDeviceStart\|StartIO' "$COREAUDIO_LOG"); ca_audio_dev_start=${ca_audio_dev_start:-0}
ca_overload=$(count_matches 'IOWorkLoop: skipping cycle' "$COREAUDIO_LOG"); ca_overload=${ca_overload:-0}

echo "CoreAudio / AUHAL counts:"
echo "  -10877 / FormatNotSupported: $ca_format_err"
echo "  AudioDeviceStart / StartIO:  $ca_audio_dev_start"
echo "  IOWorkLoop overloads:        $ca_overload"
echo

if [ "$driver_addclient_count" -gt 0 ] && [ "$driver_startio_count" -eq 0 ]; then
  echo "VERDICT: Driver received AddDeviceClient but NEVER received StartIO."
  echo "         That confirms coreaudiod is not actually wiring the IOProc through to"
  echo "         the driver, even though the Swift AudioOutputUnitStart returned noErr."
  echo "         Inspect $COREAUDIO_LOG for the matching -10877/FormatNotSupported line."
elif [ "$driver_startio_count" -gt 0 ] && [ "$driver_readinput_count" -eq 0 ]; then
  echo "VERDICT: Driver received StartIO but no ReadInput. The capture client is started"
  echo "         but coreaudiod never schedules input IO — most likely a stream"
  echo "         direction/usage problem. Inspect WillDoIOOperation entries in the"
  echo "         driver log to see which operations are scheduled."
elif [ "$driver_readinput_count" -gt 0 ]; then
  echo "VERDICT: ReadInput is being called. Cross-check the peak in the matching"
  echo "         WriteMix logs to see whether the ring buffer carried real samples."
fi
