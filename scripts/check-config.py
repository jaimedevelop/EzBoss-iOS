#!/usr/bin/env python3
"""Validate mobile public configuration without logging its values or using a provider."""
import argparse
import pathlib
import plistlib
import re
from urllib.parse import urlsplit

ROOT = pathlib.Path(__file__).resolve().parents[1]
PUBLIC = {"AUTH0_DOMAIN", "AUTH0_CLIENT_ID", "AUTH0_AUDIENCE", "API_BASE_URL"}
FIELDS = ("Auth0Domain", "Auth0ClientId", "Auth0Audience", "APIBaseURL")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=pathlib.Path, help="Built .app directory")
    parser.add_argument("--require-config", action="store_true", help="Fail if any live configuration is absent")
    parser.add_argument("--require-release-identity", action="store_true", help="Require a non-development bundle identifier for distribution")
    args = parser.parse_args()
    local = ROOT / "Config/Local.xcconfig"
    if local.exists():
        for number, line in enumerate(local.read_text().splitlines(), 1):
            line = line.strip()
            if not line or line.startswith("//"):
                continue
            key, sep, value = line.partition("=")
            if not sep or key.strip() not in PUBLIC:
                raise ValueError(f"Local.xcconfig:{number}: only the four public mobile settings are allowed")
            # Prevent includes, build-setting expansion and multi-line injection in public values.
            value = value.replace("$()", "")  # permitted xcconfig URL slash separator
            if "$(" in value or "#include" in value or ";" in value or "\\" in value:
                raise ValueError(f"Local.xcconfig:{number}: unsupported public value syntax")
    source = plistlib.loads((ROOT / "EzBoss/Info.plist").read_bytes())
    expected = dict(zip(FIELDS, ("$(AUTH0_DOMAIN)", "$(AUTH0_CLIENT_ID)", "$(AUTH0_AUDIENCE)", "$(API_BASE_URL)")))
    if any(source.get(key) != value for key, value in expected.items()):
        raise ValueError("Info.plist must reference only the four public build settings")
    for key in source:
        if re.search(r"secret|password|private.?key|access.?token|refresh.?token|management", key, re.I):
            raise ValueError("Server credential field found in Info.plist")
    if not args.app:
        if args.require_config or args.require_release_identity:
            raise ValueError("--require-config / --require-release-identity needs --app so the actual built values can be checked")
        print("PASS: source mobile configuration boundary")
        return
    info = plistlib.loads((args.app / "Info.plist").read_bytes())
    for key in info:
        if re.search(r"secret|password|private.?key|access.?token|refresh.?token|management", key, re.I):
            raise ValueError("Server credential field found in built Info.plist")
    bundle = info.get("CFBundleIdentifier", "")
    schemes = [scheme for entry in info.get("CFBundleURLTypes", []) for scheme in entry.get("CFBundleURLSchemes", [])]
    if schemes != [bundle] or not re.fullmatch(r"[a-z][a-z0-9-]*(?:\.[a-z0-9-]+)+", bundle):
        raise ValueError("Built callback scheme must exactly match the app bundle identifier")
    values = [info.get(key, "") for key in FIELDS]
    if not any(values) and not (args.require_config or args.require_release_identity):
        print("PASS: unconfigured bootstrap; callback scheme matches bundle; live sign-in is disabled")
        return
    invalid = [key for key, value in zip(FIELDS, values)
               if not isinstance(value, str) or not value or re.search(r"YOUR_|CHANGE_ME|\$\(|\s", value, re.I)]
    if not invalid:
        domain, client, _, api = values
        if not re.fullmatch(r"(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,63}", domain):
            invalid.append("Auth0Domain")
        if not re.fullmatch(r"[A-Za-z0-9_-]+", client):
            invalid.append("Auth0ClientId")
        try:
            url = urlsplit(api)
            if url.scheme != "https" or not url.hostname or url.username is not None or url.password is not None or "?" in api or "#" in api or (url.port is not None and not 1 <= url.port <= 65535):
                invalid.append("APIBaseURL")
        except ValueError:
            invalid.append("APIBaseURL")
    if invalid:
        raise ValueError("Missing or invalid public configuration fields: " + ", ".join(invalid))
    if args.require_release_identity and bundle.startswith("local."):
        raise ValueError("Replace the temporary bundle identifier before distribution")
    print("PASS: built public configuration and callback scheme; verify Native client ownership/allowlists in Auth0 separately")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, plistlib.InvalidFileException):
        # Our explicit validation messages contain names/line numbers only. Do not
        # expose parser errors, file contents or provider payloads to build logs.
        import sys
        error = sys.exc_info()[1]
        if type(error) is ValueError and str(error).startswith(("Local.xcconfig:", "Info.plist", "Server credential", "--require-config", "Built callback", "Missing or invalid", "Replace the temporary")):
            print(str(error), file=sys.stderr)
        else:
            print("Configuration could not be validated; inspect the named files locally.", file=sys.stderr)
        sys.exit(1)
