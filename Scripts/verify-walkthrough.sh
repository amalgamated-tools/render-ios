#!/bin/bash
# Extract one frame per caption beat and tile them into contact sheets, so you can see at a glance
# whether the tour actually visited the screens its captions claim.
#
#   Scripts/verify-walkthrough.sh                     # docs/walkthrough.mov -> .context/verify/
#   Scripts/verify-walkthrough.sh /tmp/demo.mov
#
# The recorder drives the app by coordinate with no idea what is on screen, so a single missed tap
# doesn't fail — it silently aims every later tap at the wrong screen, and the captions keep
# narrating the tour that was supposed to happen. That failure is invisible in the console output and
# obvious in a contact sheet, which is the whole reason this exists.
#
# **Seek accurately or not at all.** `ffmpeg -ss <t> -i <file>` seeks to the nearest keyframe, and
# simctl records variable frame rate with sparse keyframes — frames came back tens of seconds from
# where they were asked for, out of order, which reads exactly like a tour that jumped around. This
# decodes the file once at 1 fps instead, so frame N is second N and the mapping needs no trust.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOVIE="${1:-$REPO_ROOT/docs/walkthrough.mov}"
CAPTIONS="${MOVIE%.*}.txt"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/.context/verify}"

for f in "$MOVIE" "$CAPTIONS"; do
  if [ ! -f "$f" ]; then
    echo "!!! No $f — record first with: make walkthrough" >&2
    exit 1
  fi
done

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/seconds"

echo "==> Decoding $MOVIE at 1 fps"
# Numbered from 0, so second S is seconds/S.png with no arithmetic in between.
ffmpeg -v error -i "$MOVIE" -vf "fps=1,scale=300:-1" -start_number 0 "$OUT_DIR/seconds/%04d.png" -y

echo "==> Picking the frame for each beat"
# Through beats-to-srt.py rather than off the beats file directly, so this samples the same corrected
# timeline the burned-in subtitles use. Reading the raw beat seconds would put every frame up to
# three seconds from where the caption will actually appear — and verifying against the uncorrected
# times is how you'd conclude the video is fine when the subtitles are the thing that's wrong.
python3 "$REPO_ROOT/Scripts/beats-to-srt.py" "$CAPTIONS" --movie "$MOVIE" > "$OUT_DIR/cues.srt"

index=0
while IFS=$'\t' read -r seconds caption; do
  # A cue starts the moment its tap returned, before the hold — so sample a second in, by which time
  # the screen it describes has rendered.
  frame="$OUT_DIR/seconds/$(printf '%04d' $((seconds + 1))).png"
  [ -f "$frame" ] || frame="$OUT_DIR/seconds/$(printf '%04d' "$seconds").png"
  index=$((index + 1))
  cp "$frame" "$OUT_DIR/$(printf '%02d' "$index")-$(printf '%04d' "$seconds").png"
  printf '  %02d  %4ds  %s\n' "$index" "$seconds" "$caption"
done < <(python3 - "$OUT_DIR/cues.srt" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().splitlines()
for i, line in enumerate(lines):
    match = re.match(r"^(\d\d):(\d\d):(\d\d),\d+ -->", line)
    if match:
        h, m, s = (int(g) for g in match.groups())
        print(f"{h * 3600 + m * 60 + s}\t{lines[i + 1]}")
PY
)

echo "==> Tiling"
# 4x4 per sheet: small enough that a whole sheet is legible at once, and 16 beats is roughly a
# section of the tour.
ffmpeg -v error -pattern_type glob -i "$OUT_DIR/[0-9][0-9]-*.png" \
  -filter_complex tile=4x4 "$OUT_DIR/sheet%d.png" -y

rm -rf "$OUT_DIR/seconds"
echo "==> Wrote $(ls "$OUT_DIR"/sheet*.png | wc -l | tr -d ' ') contact sheets to $OUT_DIR"
echo "    Check each frame against its caption; a screen that doesn't match means the tour drifted."
