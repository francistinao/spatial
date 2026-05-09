#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DRIVER_DST="/Library/Audio/Plug-Ins/HAL/SpatialSpeaker.driver"

CANDIDATES=(
  "$PROJECT_ROOT/.build-derived/Build/Products/Debug/SpatialSpeaker.driver"
  "$PROJECT_ROOT/.driver-build/Build/Products/Debug/SpatialSpeaker.driver"
  "$PROJECT_ROOT/build/Debug/SpatialSpeaker.driver"
  "/Users/garuda/Library/Developer/Xcode/DerivedData/Spatial-eahfbtfhujdiuvfywgayilfdjgft/Build/Products/Debug/SpatialSpeaker.driver"
)

DRIVER_SRC=""
NEWEST_MTIME=0
for candidate in "${CANDIDATES[@]}"; do
  if [ -d "$candidate" ]; then
    mtime="$(stat -f '%m' "$candidate" 2>/dev/null || echo 0)"
    if [ "$mtime" -gt "$NEWEST_MTIME" ]; then
      DRIVER_SRC="$candidate"
      NEWEST_MTIME="$mtime"
    fi
  fi
done

if [ -z "$DRIVER_SRC" ]; then
  echo "Could not find SpatialSpeaker.driver in any known build output path." >&2
  printf 'Checked:\n' >&2
  printf '  %s\n' "${CANDIDATES[@]}" >&2
  exit 1
fi

echo "Installing SpatialSpeaker HAL driver from: $DRIVER_SRC"

INFO_PLIST="$DRIVER_SRC/Contents/Info.plist"
EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST" 2>/dev/null || true)"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST" 2>/dev/null || true)"
SOURCE_CODESIGN_INFO="$(codesign -dv --verbose=4 "$DRIVER_SRC" 2>&1 || true)"
SOURCE_SIGNATURE="$(printf '%s\n' "$SOURCE_CODESIGN_INFO" | sed -n 's/^Signature=//p' | head -1)"

if [[ -z "$EXECUTABLE_NAME" || "$EXECUTABLE_NAME" == *'$('* || -z "$BUNDLE_ID" || "$BUNDLE_ID" == *'$('* ]]; then
  echo "Refusing to install an unprocessed driver bundle." >&2
  echo "Build the SpatialSpeaker target first, then install the generated .driver bundle from Xcode's build products." >&2
  echo "Found CFBundleExecutable='$EXECUTABLE_NAME' CFBundleIdentifier='$BUNDLE_ID'" >&2
  exit 1
fi

if [[ -z "${SPATIAL_CODESIGN_IDENTITY:-}" && "${SOURCE_SIGNATURE:-}" == "adhoc" && "${SPATIAL_ALLOW_ADHOC_DRIVER:-0}" != "1" ]]; then
  echo "Refusing to install an ad-hoc signed HAL driver." >&2
  echo "macOS is currently rejecting SpatialSpeaker.driver when it is ad-hoc signed." >&2
  echo "Provide a real signing identity before installing, for example:" >&2
  echo "  xcodebuild ... SPATIAL_DEVELOPMENT_TEAM=YOURTEAMID SPATIAL_CODESIGN_IDENTITY='Apple Development'" >&2
  echo "  SPATIAL_CODESIGN_IDENTITY='Apple Development: Your Name (TEAMID)' Drivers/SpatialSpeaker/install.sh" >&2
  echo "If you intentionally want the old behavior for debugging only, set SPATIAL_ALLOW_ADHOC_DRIVER=1." >&2
  exit 1
fi

if [[ -n "${SPATIAL_CODESIGN_IDENTITY:-}" ]]; then
  echo "Signing SpatialSpeaker HAL driver build product with identity: $SPATIAL_CODESIGN_IDENTITY"
  codesign --force --sign "$SPATIAL_CODESIGN_IDENTITY" --deep "$DRIVER_SRC"
  sudo rm -rf "$DRIVER_DST"
  sudo cp -R "$DRIVER_SRC" "$DRIVER_DST"
else
  echo "No SPATIAL_CODESIGN_IDENTITY configured; preserving the build product signature."
  sudo rm -rf "$DRIVER_DST"
  sudo cp -R "$DRIVER_SRC" "$DRIVER_DST"
fi
sudo launchctl stop com.apple.audio.coreaudiod || true
sudo launchctl start com.apple.audio.coreaudiod

echo "Done. Verifying..."
sleep 2

codesign -dv --verbose=4 "$DRIVER_DST" 2>&1 | sed -n '1,12p'

if ! system_profiler SPAudioDataType | grep -i "Spatial"; then
  echo "WARNING: Spatial Speaker not visible yet — may need reboot or additional signing changes."
fi
