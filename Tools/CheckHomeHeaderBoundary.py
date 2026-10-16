#!/usr/bin/env python3
"""Check the gap below the home Receive button at every recorded video frame.

For the light, default-size, English, two-button layout: provide a home-only
interval starting at rest and ending before search, upward scroll, or exit.
Two thin vertical samples locate the white Receive pill and the pale body edge
between the buttons. The gap must stay at its initial size through every pull
and release. No FPS conversion; ffmpeg/ffprobe are the only dependencies.
"""
import argparse
import json
import statistics
import subprocess


def read(*args):
    return subprocess.check_output(args)


def pale_runs(pixels, column, rows):
    start = None
    for y in range(rows):
        offset = y * 6 + column * 3
        pale = y > rows * 0.14 and min(pixels[offset:offset + 3]) >= 220
        if pale and start is None:
            start = y
        elif not pale and start is not None:
            if y - start >= 8:
                yield start, y
            start = None
    if start is not None:
        yield start, rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("video")
    parser.add_argument("--start", type=float, required=True)
    parser.add_argument("--end", type=float, required=True)
    parser.add_argument("--expect-failure", action="store_true")
    args = parser.parse_args()
    if not 0 <= args.start < args.end:
        parser.error("Expected 0 <= start < end")
    metadata = json.loads(read("ffprobe", "-v", "error", "-select_streams", "v:0",
                              "-show_entries", "stream=width,height:frame=best_effort_timestamp_time",
                              "-of", "json", args.video))
    stream = metadata["streams"][0]
    width, height = stream["width"], stream["height"]
    rows = 600
    pixels = read("ffmpeg", "-v", "error", "-i", args.video, "-filter_complex",
                  f"[0:v]split[l][r];[l]crop=10:{height}:{int(width * .13) // 2 * 2}:0,scale=1:{rows}[a];"
                  f"[r]crop=10:{height}:{width // 4 * 2}:0,scale=1:{rows}[b];"
                  "[a][b]hstack,settb=1/1000,setpts=N",
                  "-fps_mode", "passthrough", "-enc_time_base", "1:600000",
                  "-f", "rawvideo", "-pix_fmt", "rgb24", "-")
    frames = metadata["frames"]
    # Raw bytes use sequential output timestamps to tolerate recording startup
    # discontinuities. Selection still uses original metadata and frame order.
    if len(pixels) != len(frames) * rows * 6:
        raise RuntimeError("Decoded frame count does not match timestamps")
    samples, missing = [], []
    for index, frame in enumerate(frames):
        time = float(frame["best_effort_timestamp_time"])
        if not args.start <= time <= args.end:
            continue
        frame_pixels = pixels[index * rows * 6:(index + 1) * rows * 6]
        button = next(pale_runs(frame_pixels, 0, rows), None)
        body = next(pale_runs(frame_pixels, 1, rows), None)
        if button is None or body is None:
            missing.append({"frame": index, "seconds": time})
        else:
            samples.append({"frame": index, "seconds": time, "gap": body[0] - button[1]})
    baseline = statistics.median(s["gap"] for s in samples[:12]) if samples else 0
    failures = [s for s in samples if s["gap"] <= 0 or abs(s["gap"] - baseline) > 2]
    detected_failure = bool(failures or missing) or baseline <= 0 or not samples
    passed = detected_failure == args.expect_failure
    print(json.dumps({"video": args.video, "interval": [args.start, args.end],
                      "frames_inspected": len(samples) + len(missing),
                      "frame_range": [samples[0]["frame"], samples[-1]["frame"]] if samples else [],
                      "sample_height": rows, "baseline_gap": baseline,
                      "gap_range": [min(s["gap"] for s in samples), max(s["gap"] for s in samples)] if samples else [],
                      "boundary_failure_count": len(failures), "failure_examples": failures[:12],
                      "untracked_frames": missing[:12], "untracked_count": len(missing),
                      "expected_failure": args.expect_failure, "passed": passed}, indent=2))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
