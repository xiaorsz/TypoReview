#!/usr/bin/env python3
"""
Archive and upload an iOS app to TestFlight using xcodebuild.
"""

from __future__ import annotations

import argparse
import plistlib
import shlex
import subprocess
import sys
import tempfile
from datetime import datetime
from pathlib import Path

try:
    import tomllib  # type: ignore[attr-defined]
except ModuleNotFoundError:  # pragma: no cover
    tomllib = None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Archive and upload an iOS app to TestFlight.")
    parser.add_argument("--config", default="codex.testflight.toml", help="Path to TOML config file.")
    parser.add_argument("--project", help="Xcode project path.")
    parser.add_argument("--workspace", help="Xcode workspace path.")
    parser.add_argument("--scheme", help="Shared scheme name.")
    parser.add_argument("--team-id", help="Apple Developer team ID.")
    parser.add_argument("--configuration", help="Build configuration. Defaults to Release.")
    parser.add_argument("--archive-path", help="Optional archive output path.")
    parser.add_argument("--xcodegen-command", help="Optional command to run before archiving.")
    parser.add_argument("--skip-xcodegen", action="store_true", help="Skip xcodegen even if configured.")
    parser.add_argument("--allow-provisioning-updates", action="store_true", help="Pass -allowProvisioningUpdates to xcodebuild.")
    parser.add_argument("--dry-run", action="store_true", help="Print commands without executing them.")
    return parser.parse_args()


def load_config(path: Path) -> dict:
    if not path.exists():
        return {}
    if tomllib is not None:
        with path.open("rb") as handle:
            document = tomllib.load(handle)
        return document.get("testflight", {})
    return parse_basic_toml_section(path, "testflight")


def parse_basic_toml_section(path: Path, section_name: str) -> dict:
    current_section = None
    values: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            current_section = line[1:-1].strip()
            continue
        if current_section != section_name or "=" not in line:
            continue
        key, raw_value = line.split("=", 1)
        key = key.strip()
        value = raw_value.strip()
        if value.startswith('"') and value.endswith('"'):
            value = value[1:-1]
        values[key] = value
    return values


def merge_config(args: argparse.Namespace, file_config: dict) -> dict:
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    config = {
        "project": file_config.get("project"),
        "workspace": file_config.get("workspace"),
        "scheme": file_config.get("scheme"),
        "team_id": file_config.get("team_id"),
        "configuration": file_config.get("configuration", "Release"),
        "archive_path": file_config.get("archive_path", f"/tmp/testflight-{timestamp}.xcarchive"),
        "xcodegen_command": file_config.get("xcodegen_command"),
    }
    cli_overrides = {
        "project": args.project,
        "workspace": args.workspace,
        "scheme": args.scheme,
        "team_id": args.team_id,
        "configuration": args.configuration,
        "archive_path": args.archive_path,
        "xcodegen_command": args.xcodegen_command,
    }
    for key, value in cli_overrides.items():
        if value:
            config[key] = value
    config["skip_xcodegen"] = args.skip_xcodegen
    config["allow_provisioning_updates"] = args.allow_provisioning_updates
    config["dry_run"] = args.dry_run
    validate_config(config)
    return config


def validate_config(config: dict) -> None:
    if not config.get("project") and not config.get("workspace"):
        raise SystemExit("Config must provide either 'project' or 'workspace'.")
    if config.get("project") and config.get("workspace"):
        raise SystemExit("Config cannot provide both 'project' and 'workspace'.")
    if not config.get("scheme"):
        raise SystemExit("Config must provide 'scheme'.")
    if not config.get("team_id"):
        raise SystemExit("Config must provide 'team_id'.")


def run_command(command: list[str], dry_run: bool, cwd: Path | None = None) -> None:
    pretty = " ".join(shlex.quote(part) for part in command)
    print(f"$ {pretty}")
    if dry_run:
        return
    subprocess.run(command, check=True, cwd=str(cwd) if cwd else None)


def run_shell(command: str, dry_run: bool, cwd: Path | None = None) -> None:
    print(f"$ {command}")
    if dry_run:
        return
    subprocess.run(command, shell=True, check=True, cwd=str(cwd) if cwd else None)


def build_base_command(config: dict) -> list[str]:
    command = ["xcodebuild"]
    if config.get("project"):
        command.extend(["-project", config["project"]])
    else:
        command.extend(["-workspace", config["workspace"]])
    command.extend([
        "-scheme",
        config["scheme"],
        "-configuration",
        config["configuration"],
    ])
    if config.get("allow_provisioning_updates"):
        command.append("-allowProvisioningUpdates")
    return command


def write_export_options(team_id: str) -> Path:
    temp_dir = Path(tempfile.mkdtemp(prefix="codex-testflight-"))
    plist_path = temp_dir / "ExportOptions.plist"
    payload = {
        "destination": "upload",
        "manageAppVersionAndBuildNumber": True,
        "method": "app-store-connect",
        "signingStyle": "automatic",
        "teamID": team_id,
        "uploadSymbols": True,
    }
    with plist_path.open("wb") as handle:
        plistlib.dump(payload, handle)
    return plist_path


def main() -> int:
    args = parse_args()
    config_path = Path(args.config)
    file_config = load_config(config_path)
    config = merge_config(args, file_config)

    repo_root = config_path.resolve().parent if config_path.exists() else Path.cwd()
    print("Using TestFlight config:")
    for key in ("project", "workspace", "scheme", "team_id", "configuration", "archive_path"):
        if config.get(key):
            print(f"  {key}: {config[key]}")

    if config.get("xcodegen_command") and not config.get("skip_xcodegen"):
        run_shell(config["xcodegen_command"], config["dry_run"], cwd=repo_root)

    archive_path = Path(config["archive_path"]).expanduser()
    export_options = write_export_options(config["team_id"])

    archive_command = build_base_command(config)
    archive_command.extend([
        "-destination",
        "generic/platform=iOS",
        "-archivePath",
        str(archive_path),
        "archive",
    ])
    run_command(archive_command, config["dry_run"], cwd=repo_root)

    upload_command = ["xcodebuild", "-exportArchive", "-archivePath", str(archive_path), "-exportOptionsPlist", str(export_options)]
    run_command(upload_command, config["dry_run"], cwd=repo_root)

    if not config["dry_run"]:
        print("Upload request submitted to App Store Connect.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
