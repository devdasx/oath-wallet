"""Check public security examples against their exact released Git revision.
Usage: python3 scripts/verify-source-excerpts.py /path/to/public/oath-wallet
Reads Git objects only; never reads ignored local credentials.
"""
import json
from pathlib import Path
import subprocess
import sys
site=Path(__file__).resolve().parents[1]
evidence=json.loads((site/'content/release-evidence.json').read_text())
repo=sys.argv[1]
for entry in evidence['files']:
    source=subprocess.run(['git','show',f"{evidence['source_commit']}:{entry['path']}"],cwd=repo,check=True,capture_output=True,text=True).stdout
    excerpt=''.join(source.splitlines(keepends=True)[entry['start']-1:entry['end']])
    if excerpt != entry['code']:
        raise SystemExit('Source excerpt mismatch: '+entry['path'])
print(f"Verified {len(evidence['files'])} exact source excerpts at {evidence['source_commit']}.")
