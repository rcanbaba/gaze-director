#!/bin/bash
# Builds the eye probe against the app's tracking code and runs it on a still image.
# Usage: Tools/eye-probe.sh <image> [x y width height]
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=Tools/out
mkdir -p "$OUT"

xcrun swiftc -O -module-name GazeCore -parse-as-library -emit-library -static \
  -emit-module -emit-module-path "$OUT/GazeCore.swiftmodule" \
  -o "$OUT/libGazeCore.a" GazeCore/Sources/GazeCore/*.swift

xcrun swiftc -O -I "$OUT" -L "$OUT" -lGazeCore -o "$OUT/eye-probe" \
  Tools/EyeProbe/main.swift GazeDirector/Tracking/FaceTracker.swift GazeDirector/Tracking/LumaSampler.swift

"$OUT/eye-probe" "$1" "$OUT/eye-probe.png" "${@:2}"
