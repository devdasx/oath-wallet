#!/usr/bin/env python3
"""Check geometry-only refresh diagnostics for a reversed move under a drag.

A finger continuing downward must not make the content jump upward. Checking
only the final resting screenshot (or only the card's lower edge) misses this.
The recorded samples contain no wallet data. Use --expect-jump on the old trace
as a positive control; use --require-attached on the native implementation.
"""
import argparse
import json


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace")
    parser.add_argument("--expect-jump", action="store_true")
    parser.add_argument("--require-attached", action="store_true")
    args = parser.parse_args()
    data = json.load(open(args.trace))
    frames = data["frames"]
    reversals = []
    for previous, current in zip(frames, frames[1:]):
        if (previous["dragging"] and current["dragging"]
                and previous["pan"] == 2 and current["pan"] == 2
                and not previous["decelerating"] and not current["decelerating"]
                and previous["offset"] < 0 and current["offset"] < 0
                and current["translation"] >= previous["translation"]
                and current["presented"] - previous["presented"] > 10):
            reversals.append({"seconds": current["t"] - frames[0]["t"],
                              "reverse_points": current["presented"] - previous["presented"],
                              "finger_delta": current["translation"] - previous["translation"]})
    intervals = []
    start = None
    for frame in frames:
        if frame["refreshing"] and start is None:
            start = frame["t"]
        elif not frame["refreshing"] and start is not None:
            intervals.append({"duration": frame["t"] - start,
                              "ended_during_drag": bool(frame["dragging"]),
                              "ended_during_deceleration": bool(frame["decelerating"])})
            start = None
    detached = sum(not frame.get("controlAttached", 0) for frame in frames)
    work_starts = [float(e["t"]) for e in data["events"] if e["event"] == "work.start"]
    work_ends = [float(e["t"]) for e in data["events"] if e["event"] == "work.end"]
    durations = [end - begin for begin, end in zip(work_starts, work_ends)]
    passed = bool(reversals) == args.expect_jump
    if args.require_attached:
        passed &= (detached == 0 and len(intervals) >= 2 and start is None
                   and len(work_starts) == len(work_ends)
                   and all(i["duration"] >= 0.39 and not i["ended_during_drag"]
                           and not i["ended_during_deceleration"] for i in intervals))
    print(json.dumps({"trace": args.trace, "frames": len(frames),
                      "reverse_jumps": reversals, "refresh_intervals": intervals,
                      "background_work_seconds": durations,
                      "detached_frames": detached if args.require_attached else None,
                      "passed": bool(passed)}, indent=2))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
