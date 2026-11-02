#!/bin/bash
# Builds and runs the warp contact-sheet tool against the real shader and MetalWarper.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=Tools/out
mkdir -p "$OUT"

xcrun swiftc -O -module-name GazeCore -parse-as-library -emit-library -static \
  -emit-module -emit-module-path "$OUT/GazeCore.swiftmodule" \
  -o "$OUT/libGazeCore.a" GazeCore/Sources/GazeCore/*.swift

xcrun swiftc -O -I "$OUT" -L "$OUT" -lGazeCore -o "$OUT/warp-preview" \
  Tools/WarpPreview/main.swift GazeDirector/Render/MetalWarper.swift

"$OUT/warp-preview" GazeDirector/Render/EyeWarp.metal "$OUT/warp-preview.png"
