#!/usr/bin/env python3
"""Detect the pale status-area flash in a LIGHT-mode home refresh recording.

Pass the home-only time interval (exclude onboarding, sheets, and app exit).
Requires ffmpeg/ffprobe. Samples both status-bar margins, away from white system
glyphs and the Dynamic Island, at every recorded frame without FPS resampling.
This checks exposed pale background, not all possible rendering defects.
"""
import argparse
import json
import subprocess


def run(*args):
    return subprocess.check_output(args)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("video")
    parser.add_argument("--start", type=float, required=True)
    parser.add_argument("--end", type=float, required=True)
    parser.add_argument("--expect-gaps", action="store_true")
    args = parser.parse_args()
    if not 0 <= args.start < args.end:
        parser.error("Expected 0 <= start < end")

    metadata = json.loads(run("ffprobe", "-v", "error", "-select_streams", "v:0",
                              "-show_entries", "stream=width,height:frame=best_effort_timestamp_time",
                              "-of", "json", args.video))
    stream = metadata["streams"][0]
    width, height = stream["width"], stream["height"]
    even = lambda n: max(2, int(n) // 2 * 2)
    x, y = even(width * 0.04), even(height * 0.025)
    w, h = even(width * 0.02), even(height * 0.01)
    right = width - x - w
    pixels = run("ffmpeg", "-v", "error", "-i", args.video, "-filter_complex",
                 f"[0:v]split[l][r];[l]crop={w}:{h}:{x}:{y},scale=1:1[a];"
                 f"[r]crop={w}:{h}:{right}:{y},scale=1:1[b];"
                 "[a][b]hstack,settb=1/1000,setpts=N",
                 "-fps_mode", "passthrough", "-enc_time_base", "1:600000",
                 "-f", "rawvideo", "-pix_fmt", "rgb24", "-")
    frames = metadata["frames"]
    if len(pixels) != len(frames) * 6:
        raise RuntimeError("Decoded frame count does not match timestamps")

    gaps, checked = [], 0
    for index, frame in enumerate(frames):
        time = float(frame["best_effort_timestamp_time"])
        if args.start <= time <= args.end:
            checked += 1
            samples = list(pixels[index * 6:index * 6 + 6])
            if min(samples[:3]) >= 215 or min(samples[3:]) >= 215:
                gaps.append({"frame": index, "seconds": time, "margin_rgb": samples})
    passed = checked > 0 and bool(gaps) == args.expect_gaps
    print(json.dumps({"video": args.video, "interval": [args.start, args.end],
                      "frames_inspected": checked, "pale_background_frames": gaps,
                      "expected_gaps": args.expect_gaps, "passed": passed}, indent=2))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
