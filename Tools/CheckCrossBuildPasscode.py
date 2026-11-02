#!/usr/bin/env python3
"""Exercise a same-install downgrade using two real source trees and synthetic data.

Usage: python3 Tools/CheckCrossBuildPasscode.py /path/to/extracted/older-source
The older checkout must predate Polkadot and contain CheckMultiWallet.py.
Run the current writer, the unmodified historical reader, then the current
reader over the same installation. No app source or production data is edited.
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def overlay(source, destination, overrides):
    """Link untouched subtrees. Copy only the entries the host fixture replaces."""
    destination.mkdir()
    for child in source.iterdir():
        if child.name.startswith("."):
            continue
        at = destination / child.name
        if child.name in overrides:
            at.write_bytes(overrides[child.name])
            continue
        nested = {key.partition("/")[2]: value for key, value in overrides.items()
                  if key.startswith(child.name + "/")}
        if nested:
            overlay(child, at, nested)
        else:
            at.symlink_to(child, target_is_directory=child.is_dir())


def run(source, work, mode, fixture, scratch):
    runner = Path("Tools/CheckMultiWallet.py")
    main = Path("Tools/CheckMultiWalletEnvelope.swift")
    overrides = {str(main): (ROOT / "Tools/CheckCrossBuildPasscode.swift").read_bytes(),
                 str(runner): (source / runner).read_bytes()}
    overlay(source, work, overrides)
    env = dict(os.environ, OATH_VALIDATION_SCRATCH=os.environ.get("OATH_CROSS_" + ("OLDER" if mode == "older" else "CURRENT") + "_SCRATCH", str(scratch)), OATH_SYNTHETIC_UPGRADE_DIR=str(fixture),
               OATH_SYNTHETIC_UPGRADE_MODE=mode)
    subprocess.run([sys.executable, str(work / runner), "--envelope"], check=True, env=env)
    return Path(env["OATH_VALIDATION_SCRATCH"]).resolve() / "debug/WalletValidation"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("older_source", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="oath-cross-build-") as directory:
        work = Path(directory)
        fixture = work / "fixture"
        fixture.mkdir()
        current = run(ROOT, work / "writer", "write", fixture, work / "writer-build")
        run(args.older_source.resolve(), work / "older", "older", fixture, work / "reader-build")
        # Reopen with the exact writer executable, including its original
        # package resources, after the older process has exited.
        subprocess.run([str(current)], check=True, env=dict(os.environ,
            OATH_TEST_WORDLISTS=str(ROOT / "OathApp/Resources/BIP39"),
            OATH_SYNTHETIC_UPGRADE_DIR=str(fixture), OATH_SYNTHETIC_UPGRADE_MODE="return"))
