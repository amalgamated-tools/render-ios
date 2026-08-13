#!/bin/bash
# Burn a walkthrough's captions into the picture, so they survive a player with no subtitle menu.
#
#   Scripts/burn-captions.sh                                   # docs/walkthrough.mov -> …-captioned.mp4
#   MOVIE=/tmp/demo.mov Scripts/burn-captions.sh
#   PRESET=veryfast CRF=28 Scripts/burn-captions.sh            # a quick proof before the good encode
#
# Generates the SRT from the beats file (beats-to-srt.py) and hard-subs it with libass. Hard subs
# rather than a mov_text track because the places this video gets published — a README, a PR, Slack —
# render video without subtitle controls, so a soft track is invisible in exactly the case it's
# wanted. Mux one as well if you like; that path needs no re-encode:
#
#   ffmpeg -i in.mov -i in.srt -c copy -c:s mov_text -metadata:s:s:0 language=eng out.mov
#
# **Homebrew's plain `ffmpeg` bottle is built without libass**, so the `subtitles` filter doesn't
# exist there and the filtergraph parser reports it as "No option name near '<file>'" — which reads
# like a quoting bug and isn't. `brew install ffmpeg-full` provides a build with it; that formula is
# keg-only, so it has to be called by path. This script finds a build that actually has the filter.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

MOVIE="${MOVIE:-$REPO_ROOT/docs/walkthrough.mov}"
BEATS="${BEATS:-${MOVIE%.*}.txt}"
SRT="${SRT:-${MOVIE%.*}.srt}"
OUT="${OUT:-${MOVIE%.*}-captioned.mp4}"
CRF="${CRF:-20}"
PRESET="${PRESET:-slow}"
# Helvetica Neue, not SF Pro Text: libass resolves fonts through CoreText here and silently
# substitutes Helvetica for SF Pro Text ("fontselect: (SF Pro Text, 400, 0) -> Helvetica.ttc"), so
# asking for SF Pro is asking for a surprise. BorderStyle=4 puts a translucent box behind the text,
# which a screen recording full of white UI needs; MarginV lifts it off the home indicator.
#
# FontSize and MarginV are in libass script units against a default script height of 288 — *not*
# pixels — so both scale with the frame and need no adjustment for a different device size. 16 is
# noticeably chunkier than 12 and wraps a long beat onto four lines; MarginV=25 lands the box just
# above the tab bar, where 60 floats it into the middle of the content.
#
# To preview a style without a full encode, extract one frame — but note that seeking with -ss
# *before* -i restarts the subtitle timeline, so the frame shows cue 1 whatever timestamp you pick.
# That's fine for judging placement and useless for judging sync.
STYLE="${STYLE:-FontName=Helvetica Neue,FontSize=12,PrimaryColour=&H00FFFFFF,BackColour=&H90000000,BorderStyle=4,MarginV=25}"

# A build with libass, preferring whatever is on PATH so an explicit FFMPEG= always wins.
find_ffmpeg() {
  if [ -n "${FFMPEG:-}" ]; then echo "$FFMPEG"; return; fi
  for candidate in ffmpeg /opt/homebrew/opt/ffmpeg-full/bin/ffmpeg /usr/local/opt/ffmpeg-full/bin/ffmpeg; do
    if command -v "$candidate" > /dev/null 2>&1 \
      && "$candidate" -hide_banner -h filter=subtitles 2>&1 | grep -q libass; then
      echo "$candidate"
      return
    fi
  done
}

FF="$(find_ffmpeg)"
if [ -z "$FF" ]; then
  echo "!!! No ffmpeg with the 'subtitles' filter (libass) on this machine." >&2
  echo "    Homebrew's plain ffmpeg bottle is built without it. Install the full build:" >&2
  echo "        brew install ffmpeg-full" >&2
  echo "    It's keg-only, so this script calls it by path. Or set FFMPEG=/path/to/ffmpeg." >&2
  exit 1
fi

[ -f "$MOVIE" ] || { echo "!!! No movie at $MOVIE — run 'make walkthrough' first." >&2; exit 1; }
[ -f "$BEATS" ] || { echo "!!! No beats file at $BEATS (the recorder writes it beside the movie)." >&2; exit 1; }

echo "==> Captions: $BEATS -> $SRT"
python3 "$REPO_ROOT/Scripts/beats-to-srt.py" "$BEATS" --movie "$MOVIE" > "$SRT"
echo "    $(grep -c -- '-->' "$SRT") cues"

echo "==> Burning with $FF (crf $CRF, preset $PRESET)"
# -fps_mode passthrough because simctl records **variable** frame rate (21.9 fps average against a
# 60 fps timebase). ffmpeg's default constant-rate mode decimates the dense stretches to hit one
# rate — 2810 source frames became 2295, and the frames it drops are the ones during animation,
# which is the part of a UI recording worth watching. Passthrough keeps the source timestamps, and
# on this content it costs nothing: same duration, same file size.
"$FF" -hide_banner -v warning -stats -i "$MOVIE" \
  -vf "subtitles=$SRT:force_style='$STYLE'" \
  -c:v libx264 -crf "$CRF" -preset "$PRESET" -pix_fmt yuv420p -fps_mode passthrough \
  -y "$OUT"

echo "==> Wrote $OUT"
echo "    Both the movie and this are gitignored — publish deliberately (a GitHub release asset or"
echo "    an issue attachment), since every frame is real workspace data."
