#!/bin/bash
# Downloads the MediaPipe pose landmarker model into CoachMe/Resources/.
#
# The .task file is gitignored and carries Google's own licence
# rather than this project's. Run this once after cloning.
#
# The variant must match MediaPipePoseDetector.ModelVariant. Heavy is the
# app default; pass lite or full explicitly to download an alternative.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

VARIANT="${1:-heavy}"
case "$VARIANT" in
  lite|full|heavy) ;;
  *) echo "usage: $0 [lite|full|heavy]" >&2; exit 1 ;;
esac

NAME="pose_landmarker_${VARIANT}"
URL="https://storage.googleapis.com/mediapipe-models/pose_landmarker/${NAME}/float16/latest/${NAME}.task"
OUT="CoachMe/Resources/${NAME}.task"

mkdir -p CoachMe/Resources
echo "Downloading ${NAME}.task ..."
curl -sSL --fail -o "$OUT" "$URL"

# The .task bundle is a zip holding the two tflite models. Verify rather than
# trusting a 200 that returned an error page.
if ! unzip -l "$OUT" 2>/dev/null | grep -q "\.tflite"; then
  echo "ERROR: $OUT is not a valid .task bundle (no .tflite inside)." >&2
  rm -f "$OUT"
  exit 1
fi

echo "OK: $OUT ($(du -h "$OUT" | cut -f1))"
echo "Now run tools/setup-xcode-project.sh so it lands in Copy Bundle Resources."
