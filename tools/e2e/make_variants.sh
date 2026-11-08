#!/bin/bash
# Builds the end-to-end format matrix from one source clip with ffmpeg.
#   tools/e2e/make_variants.sh <source video> <out dir> [prefix]
# Every variant comes from the same footage, so the App and Python results can
# be compared across formats. Synthetic where noted (frame duplication is not a
# real slow-motion capture); real iPhone clips replace these once they exist.
set -euo pipefail
SRC="$1"; OUT="$2"; P="${3:-$(basename "${SRC%.*}")}"
mkdir -p "$OUT"
FF="ffmpeg -v error -y -i $SRC"
X264="-c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p -an"
X265="-c:v libx265 -preset veryfast -crf 24 -pix_fmt yuv420p -tag:v hvc1 -an -x265-params log-level=error"

W=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$SRC")
H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$SRC")
# Portrait crop around the frame centre-left (where a golfer usually stands), 9:16, even sizes.
PW=$(( (H * 9 / 16) / 2 * 2 ))
PORTRAIT="crop=${PW}:${H}:(iw*0.42-${PW}/2):0,scale=720:1280"

$FF $X264 "$OUT/${P}__h264_landscape_orig.mp4"
$FF $X265 -r 30 "$OUT/${P}__hevc_landscape_30.mp4"
$FF -vf "$PORTRAIT" $X264 -r 30 "$OUT/${P}__h264_portrait_30.mp4"
$FF -vf "$PORTRAIT" $X265 -r 60 "$OUT/${P}__hevc_portrait_60fps-dup.mp4"
$FF -vf "$PORTRAIT" $X264 -r 240 "$OUT/${P}__h264_portrait_240fps-dup.mp4"
# iPhone-style: pixels stored landscape, displayed portrait through rotation metadata.
ffmpeg -v error -y -i "$SRC" -vf "$PORTRAIT,transpose=2" $X264 -r 30 "$OUT/.rot_tmp.mp4"
ffmpeg -v error -y -display_rotation 90 -i "$OUT/.rot_tmp.mp4" -c copy "$OUT/${P}__h264_portrait_rotated-metadata.mov"
rm -f "$OUT/.rot_tmp.mp4"
# ~60 s with 4 swings: hold the first frame 12 s, play the clip; repeat 4x (PR-3 multi-swing input).
ffmpeg -v error -y -i "$SRC" -vf "tpad=start_duration=12:start_mode=clone,fps=30" $X264 "$OUT/.seg.mp4"
printf "file '%s'\n" .seg.mp4 .seg.mp4 .seg.mp4 .seg.mp4 > "$OUT/.list.txt"
ffmpeg -v error -y -f concat -safe 0 -i "$OUT/.list.txt" -c copy "$OUT/${P}__h264_landscape_60s_4swings.mp4"
rm -f "$OUT/.seg.mp4" "$OUT/.list.txt"

for f in "$OUT"/${P}__*; do
  printf '%-60s %s\n' "$(basename "$f")" "$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height,r_frame_rate:stream_side_data=rotation:format=duration -of compact=p=0:nk=1 "$f" | tr '\n' ' ')"
done
