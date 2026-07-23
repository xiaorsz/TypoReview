#!/usr/bin/env python3
"""Non-destructive smoke test for mutation sync and duplicate review rejection."""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from typing import Optional
from uuid import uuid4


BASE_URL = os.environ.get("TYPO_REVIEW_SMOKE_URL", "http://127.0.0.1:18181")
TOKEN = os.environ["API_TOKEN"]


def call(path: str, payload: dict) -> tuple[int, dict]:
    request = urllib.request.Request(
        BASE_URL + path,
        data=json.dumps(payload, separators=(",", ":")).encode(),
        headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        return error.code, json.load(error)


def mutation(entity: str, record_id: str, operation: str, payload: Optional[dict] = None) -> dict:
    value = {
        "mutationID": str(uuid4()),
        "entityType": entity,
        "recordID": record_id,
        "operation": operation,
        "updatedAt": datetime.now(timezone.utc).isoformat(),
    }
    if payload is not None:
        value["payload"] = payload
    return value


def main() -> None:
    item_id = str(uuid4())
    first_record_id = str(uuid4())
    duplicate_record_id = str(uuid4())
    now = datetime.now(timezone.utc)
    item = {
        "id": item_id,
        "typeRawValue": "englishWord",
        "content": "__server_smoke_test__",
        "prompt": "",
        "note": "",
        "source": "server smoke test",
        "stage": 0,
        "nextReviewAt": (now - timedelta(days=1)).isoformat(),
        "lastReviewedAt": None,
        "consecutiveCorrectCount": 0,
        "consecutiveWrongCount": 0,
        "isPriority": False,
        "reviewTrackRawValue": "standard",
        "dictationFollowUpStep": 0,
        "isDictationPassRaw": False,
        "createdAt": (now - timedelta(days=1)).isoformat(),
        "updatedAt": now.isoformat(),
    }
    first_record = {
        "id": first_record_id,
        "itemID": item_id,
        "reviewedAt": now.isoformat(),
        "resultRawValue": "correct",
        "modeRawValue": "scheduled",
        "oldStage": 0,
        "newStage": 1,
        "note": "server smoke test",
    }
    duplicate_record = {**first_record, "id": duplicate_record_id}

    created_status, _ = call("/v1/sync/push", {"mutations": [mutation("reviewItems", item_id, "upsert", item)]})
    first_status, _ = call(
        "/v1/sync/push",
        {"mutations": [mutation("reviewRecords", first_record_id, "upsert", first_record)]},
    )
    duplicate_status, duplicate_body = call(
        "/v1/sync/push",
        {"mutations": [mutation("reviewRecords", duplicate_record_id, "upsert", duplicate_record)]},
    )
    cleanup_status, _ = call(
        "/v1/sync/push",
        {"mutations": [
            mutation("reviewRecords", first_record_id, "delete"),
            mutation("reviewRecords", duplicate_record_id, "delete"),
            mutation("reviewItems", item_id, "delete"),
        ]},
    )
    result = {
        "createStatus": created_status,
        "firstReviewStatus": first_status,
        "duplicateReviewStatus": duplicate_status,
        "duplicateReason": duplicate_body.get("detail", {}).get("reason"),
        "cleanupStatus": cleanup_status,
    }
    print(json.dumps(result, ensure_ascii=False))
    if result != {
        "createStatus": 200,
        "firstReviewStatus": 200,
        "duplicateReviewStatus": 409,
        "duplicateReason": "item_already_reviewed_today",
        "cleanupStatus": 200,
    }:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
