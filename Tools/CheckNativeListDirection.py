#!/usr/bin/env python3
"""Check native collection boundaries for the live RTL/LTR regression.

A lexical source guard, not a rendering test. The separate
Tools/NativeRefreshPlacement/DirectionTests.swift fixture covers targeted
production refresh rendering; it does not render every collection boundary.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
# Mask comments and strings without moving offsets or counting their braces.
ignored = re.compile(r'//[^\n]*|/\*[\s\S]*?\*/|"""[\s\S]*?"""|"(?:\\.|[^"\\])*"')
collections = re.compile(r'\b(List|Form|NativeRefreshScroll)\s*(?=[({])')
paths = list((root / "OathAtmosphere").rglob("*.swift"))
paths += list((root / "OathApp").rglob("*.swift"))
failures = []
count = 0

def closing(code, start, left, right):
    depth = 1
    end = start + 1
    while depth and end < len(code):
        depth += (code[end] == left) - (code[end] == right)
        end += 1
    return end

for path in paths:
    if path.name.startswith("._"):
        continue
    source = path.read_text()
    code = ignored.sub(lambda m: "".join("\n" if c == "\n" else " " for c in m[0]), source)
    for match in collections.finditer(code):
        start = match.end()
        if code[start] == "(":
            start = closing(code, start, "(", ")")
        while start < len(code) and code[start].isspace():
            start += 1
        if start >= len(code) or code[start] != "{":
            failures.append(f"Unrecognized collection initializer: {path.relative_to(root)}")
            continue
        end = closing(code, start, "{", "}")
        count += 1
        # Identity belongs on the concrete collection call, before navigation,
        # tasks and sheets. NativeRefreshScroll includes its List + attachment
        # in one boundary; its parent screen retains model and draft state.
        # A full language identity (for example localized Help catalog content)
        # also recreates the collection whenever its direction changes.
        if not re.match(r'\s*(?:\.id\(profile\?\.id\)\s*)?\.id\(strings\.language\.(?:isRightToLeft|rawValue)\)', code[end:]):
            failures.append(f"{path.relative_to(root)}:{source[:match.start()].count(chr(10)) + 1}")
if failures:
    sys.exit("Native collections missing their direction boundary:\n" + "\n".join(failures))
print(f"Native collection direction coverage passed: {count} List/Form/NativeRefreshScroll entry points.")
