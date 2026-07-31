#!/usr/bin/env python3
"""Inspect or append the server-managed daily quote library."""

from __future__ import annotations

import argparse
import json
import os
import urllib.error
import urllib.request
from pathlib import Path


DEFAULT_URL = os.environ.get("TYPO_REVIEW_ADMIN_URL", "http://127.0.0.1:18181")
DEFAULT_FILE = Path(__file__).resolve().parents[1] / "app" / "daily_quotes.json"


def request(method: str, base_url: str, path: str, token: str, payload: dict | None = None) -> dict:
    body = None if payload is None else json.dumps(payload, ensure_ascii=False).encode("utf-8")
    headers = {
        "Accept": "application/json",
        "Authorization": f"Bearer {token}",
    }
    if body is not None:
        headers["Content-Type"] = "application/json"
    call = urllib.request.Request(
        base_url.rstrip("/") + path,
        data=body,
        headers=headers,
        method=method,
    )
    try:
        with urllib.request.urlopen(call, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        raise SystemExit(f"HTTP {error.code}: {detail}") from error


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("status", "import"))
    parser.add_argument("--base-url", default=DEFAULT_URL)
    parser.add_argument("--file", type=Path, default=DEFAULT_FILE)
    args = parser.parse_args()

    token = os.environ.get("API_TOKEN", "").strip()
    if not token:
        raise SystemExit("请先设置服务器管理令牌环境变量 API_TOKEN")

    if args.command == "status":
        result = request("GET", args.base_url, "/v1/admin/daily-quotes/status", token)
    else:
        payload = json.loads(args.file.read_text(encoding="utf-8"))
        result = request("POST", args.base_url, "/v1/admin/daily-quotes/import", token, payload)
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
