#!/usr/bin/env python3
"""Create or validate the atomic project-local toolchain provenance marker."""

import argparse
import hashlib
import os
from pathlib import Path
import platform
import tempfile


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_versions(path: Path) -> dict[str, str]:
    values = {}
    for line in path.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        key, separator, value = line.partition("=")
        if not separator:
            raise SystemExit(f"invalid versions record: {line}")
        values[key] = value
    return values


def expected(root: Path) -> tuple[list[str], dict[str, str]]:
    tools = root / "tools"
    schema_path = tools / "environment-manifest.schema"
    keys = [line for line in schema_path.read_text().splitlines() if line]
    versions = load_versions(tools / "versions.env")
    values = {
        "schema": "1",
        "schema_sha256": sha256(schema_path),
        "platform": platform.system(),
        "architecture": platform.machine(),
        "lua_version": versions["LUA_VERSION"],
        "luarocks_version": versions["LUAROCKS_VERSION"],
        "stylua_version": versions["STYLUA_VERSION"],
        "hererocks_revision": versions["HEREROCKS_REVISION"],
        "hererocks_sha256": versions["HEREROCKS_SHA256"],
        "lua_sha256": versions["LUA_SHA256"],
        "luarocks_sha256": versions["LUAROCKS_SHA256"],
        "busted_sha256": versions["BUSTED_SHA256"],
        "luacov_sha256": versions["LUACOV_SHA256"],
        "stylua_sha256": versions["STYLUA_SHA256"],
        "rock_artifacts_manifest_sha256": sha256(tools / "luarocks-artifacts.env"),
        "lock_sha256": sha256(root / "luarocks.lock"),
        "local_repository": "verified",
        "lock_graph": "verified",
        "completion": "complete",
    }
    if set(keys) != set(values) or len(keys) != len(values):
        raise SystemExit("tracked environment manifest schema does not match the implementation")
    return keys, values


def render(root: Path) -> str:
    keys, values = expected(root)
    return "".join(f"{key}={values[key]}\n" for key in keys)


def validate(root: Path, marker: Path) -> None:
    wanted = render(root)
    if not marker.is_file():
        raise SystemExit(f"environment completion marker missing: {marker}; quarantine .lua and rerun bootstrap")
    if marker.read_text() != wanted:
        raise SystemExit(f"environment completion marker mismatch: {marker}; quarantine .lua and rerun bootstrap")


def write(root: Path, marker: Path) -> None:
    marker.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=".anodyne-environment.", dir=marker.parent, text=True)
    try:
        with os.fdopen(descriptor, "w") as output:
            output.write(render(root))
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary_name, marker)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("validate", "write"))
    parser.add_argument("root", type=Path)
    parser.add_argument("marker", type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    marker = args.marker.resolve()
    if args.mode == "validate":
        validate(root, marker)
    else:
        write(root, marker)


if __name__ == "__main__":
    main()
