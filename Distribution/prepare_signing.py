#!/usr/bin/env python3
"""Materialize CI credentials in temporary storage without printing their values."""
import base64
import os
import plistlib
import subprocess
from pathlib import Path


def install(root, temporary):
    fields = {
        "ASC_API_KEY_P8_BASE64": "AuthKey.p8",
        "APPLE_DISTRIBUTION_P12_BASE64": "distribution.p12",
        "APPLE_PROVISIONING_PROFILE_BASE64": "distribution.mobileprovision",
        "OATH_PROVIDER_CONFIGURATION_BASE64": "TokenRPC.plist",
    }
    required = [*fields, "APPLE_DISTRIBUTION_PASSWORD", "ASC_KEY_ID", "ASC_ISSUER_ID"]
    missing = [name for name in required if not os.environ.get(name)]
    if missing:
        raise ValueError("Missing deployment secrets: " + ", ".join(missing))
    temporary.mkdir(parents=True, exist_ok=True, mode=0o700)
    for key, name in fields.items():
        data = base64.b64decode(os.environ[key], validate=True)
        target = temporary / name
        target.write_bytes(data)
        target.chmod(0o600)
    provider = plistlib.loads((temporary / "TokenRPC.plist").read_bytes())
    if not isinstance(provider, dict) or not provider.get("WalletConnectProjectID"):
        raise ValueError("Release provider configuration is incomplete")
    profile = plistlib.loads(subprocess.check_output([
        "security", "cms", "-D", "-i", str(temporary / "distribution.mobileprovision")]))
    entitlements = profile["Entitlements"]
    if entitlements.get("application-identifier") != "C5T44SZNQX.com.aperture.wallet":
        raise ValueError("Provisioning profile belongs to another app")
    if entitlements.get("get-task-allow") or profile.get("ProvisionedDevices") or profile.get("ProvisionsAllDevices"):
        raise ValueError("An App Store distribution profile is required")
    if profile.get("IsXcodeManaged"):
        raise ValueError("Provisioning profile must be manually managed for GitHub signing")
    from datetime import datetime, timezone
    if profile["ExpirationDate"].replace(tzinfo=timezone.utc) <= datetime.now(timezone.utc):
        raise ValueError("Provisioning profile has expired")
    local = root / "OathApp/Private/TokenRPC.plist"
    local.parent.mkdir(parents=True, exist_ok=True)
    local.write_bytes((temporary / "TokenRPC.plist").read_bytes())
    local.chmod(0o600)
    with (temporary / "profile.json").open("w") as output:
        import json
        json.dump({"name": profile["Name"], "uuid": profile["UUID"]}, output)


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--temporary", type=Path, required=True)
    args = parser.parse_args()
    try:
        install(args.root, args.temporary)
    except Exception as error:
        # Credential decoders may include input in their errors. Never echo it.
        if isinstance(error, ValueError) and str(error).startswith(("Missing deployment", "Release provider", "Provisioning", "An App Store")):
            parser.exit(1, str(error) + "\n")
        parser.exit(1, "Deployment credential validation failed; values were not logged.\n")
