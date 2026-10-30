import os
import re

if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", os.environ.get("VERSION", "")):
    raise SystemExit("Version must have three numeric components")
if not re.fullmatch(r"[1-9][0-9]*", os.environ.get("BUILD", "")):
    raise SystemExit("Build must be a positive integer")

version, build = os.environ["VERSION"], os.environ["BUILD"]
tag = os.environ.get("SOURCE_TAG", "v" + version)
if tag not in {"v" + version, "v" + version + "-build" + build}:
    raise SystemExit("Source tag must identify the requested version/build")
