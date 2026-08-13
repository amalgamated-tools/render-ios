#!/usr/bin/env python3
"""Turn a walkthrough beats file into an SRT subtitle track.

    Scripts/beats-to-srt.py docs/walkthrough.txt > docs/walkthrough.srt
    Scripts/beats-to-srt.py docs/walkthrough.txt --movie docs/walkthrough.mov > docs/walkthrough.srt

`beat` in walkthrough-lib.sh writes one line per beat, with a start time and no end time:

    00:03  Sign-in — the API key path
    00:14  The service list — every service in the active workspace

which is the right shape for narration and the wrong shape for a subtitle renderer. Each cue here
runs until the next beat starts, less a small gap so no two cues overlap. The last cue has nothing
after it to bound it: with --movie it runs to the end of the video (read with ffprobe), and without
one it gets TAIL_SECONDS.

The offsets are measured from START_EPOCH, which the recorder stamps two seconds after launching
`simctl io recordVideo`. That settling delay is deliberate, but it means the alignment is only as
good as simctl's startup. Check the first cue against the picture; if the whole track is uniformly
early or late, shift it at mux time with ffmpeg's -itsoffset rather than editing every line.
"""
import argparse
import re
import subprocess
import sys

TAIL_SECONDS = 6.0
GAP = 0.15  # a cue ends just before the next one starts

BEAT = re.compile(r"^(\d+):(\d{2})\s+(.*\S)\s*$")


def stamp(seconds):
    """Seconds as an SRT timestamp: HH:MM:SS,mmm."""
    seconds = max(seconds, 0.0)
    hours, rest = divmod(seconds, 3600)
    minutes, secs = divmod(rest, 60)
    return f"{int(hours):02d}:{int(minutes):02d}:{int(secs):02d},{round(secs % 1 * 1000):03d}"


def movie_duration(path):
    """The video's length in seconds, or None when ffprobe can't say."""
    try:
        probe = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1", path],
            capture_output=True, text=True, check=True,
        )
        return float(probe.stdout.strip())
    except (OSError, subprocess.CalledProcessError, ValueError):
        print(f"  warn: no duration from {path} — the last cue gets +{TAIL_SECONDS}s instead",
              file=sys.stderr)
        return None


def read_beats(path):
    beats = []
    with open(path) as handle:
        for number, line in enumerate(handle, 1):
            if not line.strip():
                continue
            match = BEAT.match(line)
            if not match:
                print(f"  warn: {path}:{number} isn't a beat line, skipped: {line.strip()}",
                      file=sys.stderr)
                continue
            minutes, seconds, text = match.groups()
            beats.append((int(minutes) * 60 + int(seconds), text))
    return beats


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("beats", help="the .txt written next to the recording")
    parser.add_argument("--movie", help="end the last cue at this file's duration")
    args = parser.parse_args()

    beats = read_beats(args.beats)
    if not beats:
        sys.exit(f"!!! no beats found in {args.beats}")

    duration = movie_duration(args.movie) if args.movie else None
    tail = duration if duration else beats[-1][0] + TAIL_SECONDS

    for index, (start, text) in enumerate(beats, 1):
        end = beats[index][0] - GAP if index < len(beats) else tail
        if end <= start:  # two beats stamped on the same second
            end = start + 1.0
        print(index)
        print(f"{stamp(start)} --> {stamp(end)}")
        print(text)
        print()


if __name__ == "__main__":
    main()
