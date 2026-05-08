#!/bin/bash
set -euo pipefail

IDENTITY_OUTPUT="$(security find-identity -v -p codesigning 2>/dev/null || true)"
VALID_COUNT="$(printf '%s\n' "$IDENTITY_OUTPUT" | awk '/valid identities found/ { print $1 }' | tail -1)"

echo "$IDENTITY_OUTPUT"

if [ -z "$VALID_COUNT" ] || [ "$VALID_COUNT" = "0" ]; then
  echo
  echo "No valid code-signing identities were found."
  echo "SpatialSpeaker.driver should be built and installed with a real Apple Development identity."
  echo "Example:"
  echo "  xcodebuild -project Spatial.xcodeproj -scheme SpatialSpeaker -configuration Debug -derivedDataPath .build-derived SPATIAL_DEVELOPMENT_TEAM=YOURTEAMID SPATIAL_CODESIGN_IDENTITY='Apple Development' build"
  exit 1
fi

echo
echo "At least one valid code-signing identity is available."
