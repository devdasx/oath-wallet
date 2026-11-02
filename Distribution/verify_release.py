#!/usr/bin/env python3
"""Check the exact tagged source and version before any signing or upload."""
import argparse
import json
import re
import subprocess
from pathlib import Path


def matches_release_tag(tag, version, build):
    base = "v" + version
    return tag == base or re.fullmatch(re.escape(base + "-build" + build) + r"(?:-r[1-9][0-9]*)?", tag) is not None


def inspect_release(root, tag, version, build):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("Use a numeric three-part version")
    if not re.fullmatch(r"[1-9][0-9]*", build) or not matches_release_tag(tag, version, build):
        raise ValueError("Tag must identify this version/build and build must be a positive integer")
    pbx = (root / "OathAtmosphere.xcodeproj/project.pbxproj").read_text()
    for key, expected in [("MARKETING_VERSION", version), ("CURRENT_PROJECT_VERSION", build)]:
        values = set(re.findall(r"\b" + key + r"\s*=\s*([^;]+);", pbx))
        if values != {expected}:
            raise ValueError(f"{key} does not match the requested release")
    git = lambda *args: subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()
    commit = git("rev-parse", "HEAD")
    if commit != git("rev-parse", f"refs/tags/{tag}^{{commit}}"):
        raise ValueError("Checkout is not the requested tag")
    if git("status", "--porcelain", "--untracked-files=no"):
        raise ValueError("Release source contains modifications")
    return {"version": version, "build": build, "tag": tag, "source_commit": commit}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["root", "tag", "version", "build", "output"]:
        parser.add_argument("--" + name, required=True)
    args = parser.parse_args()
    try:
        result = inspect_release(Path(args.root), args.tag, args.version, args.build)
    except (ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Release validation failed: {error}\n")
    Path(args.output).parent.mkdir(parents=True, exist_ok=True)
    Path(args.output).write_text(json.dumps(result, indent=2) + "\n")
    print(f"Verified {args.tag} ({args.build}) at {result['source_commit']}")
