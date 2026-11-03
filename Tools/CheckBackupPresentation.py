#!/usr/bin/env python3
"""Test the production all-wallet backup model with controlled host-only callbacks.

The SwiftUI page is omitted. Database, cloud service, diagnostics and vault are
synthetic boundary stubs; no encryption, real storage, iCloud, UI or device is used.
"""
import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    source = root / 'OathAtmosphere/Home/OathAllWalletBackupPage.swift'
    text = source.read_text()
    marker = '@MainActor @Observable final class OathAllWalletBackupModel {'
    if text.count(marker) != 1:
        raise ValueError('Production model boundary changed')
    model = 'import Foundation\nimport Observation\n' + marker + text.split(marker)[1]
    env = {k: v for k, v in os.environ.items() if k in {'HOME', 'PATH', 'TMPDIR', 'DEVELOPER_DIR', 'LANG', 'LC_ALL'}}
    with tempfile.TemporaryDirectory(prefix='oath-backup-presentation-') as temporary:
        work = Path(temporary)
        (work / 'Model.swift').write_text(model)
        binary = work / 'checks'
        print('Production source SHA256: ' + hashlib.sha256(source.read_bytes()).hexdigest(), flush=True)
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library',
                        str(root / 'Tools/CheckBackupPresentation.swift'), str(work / 'Model.swift'),
                        '-o', str(binary)], check=True, timeout=120, env=env)
        subprocess.run(['/usr/bin/sandbox-exec', '-p', '(version 1) (allow default) (deny network*)',
                        str(binary)], check=True, timeout=30, env=env)


if __name__ == '__main__':
    main()
