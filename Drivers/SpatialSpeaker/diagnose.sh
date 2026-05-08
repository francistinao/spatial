#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALL_DRIVER="/Library/Audio/Plug-Ins/HAL/SpatialSpeaker.driver"
BUILD_DRIVER="$PROJECT_ROOT/.build-derived/Build/Products/Debug/SpatialSpeaker.driver"
BUILD_EXECUTABLE="$BUILD_DRIVER/Contents/MacOS/SpatialSpeaker"
INSTALL_EXECUTABLE="$INSTALL_DRIVER/Contents/MacOS/SpatialSpeaker"

echo "== Spatial Speaker Diagnostics =="
echo "Date: $(date)"
echo

echo "== Signing Identities =="
security find-identity -v -p codesigning || true
echo

echo "== Installed Driver Presence =="
if [ -d "$INSTALL_DRIVER" ]; then
  echo "Installed: $INSTALL_DRIVER"
else
  echo "Installed: missing"
fi
echo

echo "== Installed Driver Signature =="
if [ -d "$INSTALL_DRIVER" ]; then
  codesign -dv --verbose=4 "$INSTALL_DRIVER" 2>&1 || true
else
  echo "Installed driver bundle is missing."
fi
echo

echo "== Build Driver Signature =="
if [ -d "$BUILD_DRIVER" ]; then
  codesign -dv --verbose=4 "$BUILD_DRIVER" 2>&1 || true
else
  echo "Build product missing at $BUILD_DRIVER"
fi
echo

echo "== Executable Hash Parity =="
if [ -f "$INSTALL_EXECUTABLE" ] && [ -f "$BUILD_EXECUTABLE" ]; then
  shasum "$INSTALL_EXECUTABLE" "$BUILD_EXECUTABLE"
else
  echo "Could not compare hashes because one or both executables are missing."
fi
echo

echo "== Driver Info.plist Factory UUIDs =="
if [ -f "$INSTALL_DRIVER/Contents/Info.plist" ]; then
  /usr/libexec/PlistBuddy -c "Print :CFPlugInFactories" "$INSTALL_DRIVER/Contents/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Print :CFPlugInTypes" "$INSTALL_DRIVER/Contents/Info.plist" 2>/dev/null || true
else
  echo "Installed driver Info.plist missing."
fi
echo

echo "== Filtered coreaudiod/amfid Logs =="
LOG_PATTERN='SpatialSpeaker|Spatial Speaker|com\.spatial\.app\.driver\.speaker|HostInterface_PropertiesChanged|Not loading the driver plug-in|adhoc signed|unknown certificate chain|F8BB1C28|hidn|IsHidden'
if command -v rg >/dev/null 2>&1; then
  log show --last 5m --info --debug --predicate 'subsystem == "com.spatial.app.driver.speaker" OR process == "coreaudiod" OR process == "amfid"' --style compact | rg "$LOG_PATTERN" || true
else
  log show --last 5m --info --debug --predicate 'subsystem == "com.spatial.app.driver.speaker" OR process == "coreaudiod" OR process == "amfid"' --style compact | grep -E "$LOG_PATTERN" || true
fi
echo

echo "== Audio Devices =="
system_profiler SPAudioDataType || true
