#!/usr/bin/env python3
"""Export TypoReview's SwiftData SQLite store as a v4 structured-data snapshot.

MediaAsset rows and media files are intentionally excluded.
"""

from __future__ import annotations

import argparse
import json
import sqlite3
import tempfile
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable


COCOA_EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc)


def uuid_value(value: bytes | None) -> str | None:
    return str(uuid.UUID(bytes=value)) if value is not None else None


def date_value(value: float | None) -> str | None:
    if value is None:
        return None
    resolved = COCOA_EPOCH + timedelta(seconds=float(value))
    return resolved.isoformat(timespec="microseconds").replace("+00:00", "Z")


def bool_value(value: int | None) -> bool:
    return bool(value or 0)


def text_value(value: str | None, default: str = "") -> str:
    return value if value is not None else default


def rows(connection: sqlite3.Connection, table: str) -> list[sqlite3.Row]:
    return list(connection.execute(f'SELECT * FROM "{table}" ORDER BY Z_PK'))


def map_rows(
    connection: sqlite3.Connection,
    table: str,
    mapper: Callable[[sqlite3.Row], dict[str, Any]],
) -> list[dict[str, Any]]:
    return [mapper(row) for row in rows(connection, table)]


def make_payload(connection: sqlite3.Connection) -> dict[str, Any]:
    settings_rows = rows(connection, "ZAPPSETTINGS")
    settings = None
    if settings_rows:
        row = settings_rows[-1]
        settings = {
            "id": uuid_value(row["ZID"]),
            "childName": text_value(row["ZCHILDNAME"]),
            "dailyLimit": row["ZDAILYLIMIT"],
            "remindHour": row["ZREMINDHOUR"],
            "remindMinute": row["ZREMINDMINUTE"],
            "reviewInteractionStyleRawValue": text_value(row["ZREVIEWINTERACTIONSTYLERAWVALUE"], "swipe"),
            "boardAutoplayEnabled": bool_value(row["ZBOARDAUTOPLAYENABLED"]),
            "boardAutoplayStartHour": row["ZBOARDAUTOPLAYSTARTHOUR"],
            "boardAutoplayStartMinute": row["ZBOARDAUTOPLAYSTARTMINUTE"],
            "boardAutoplayEndHour": row["ZBOARDAUTOPLAYENDHOUR"],
            "boardAutoplayEndMinute": row["ZBOARDAUTOPLAYENDMINUTE"],
            "boardAutoplayDurationMinutes": row["ZBOARDAUTOPLAYDURATIONMINUTES"],
            "boardAutoplaySlotsRawValue": text_value(row["ZBOARDAUTOPLAYSLOTSRAWVALUE"]),
            "boardManualPlaybackOptionRawValue": text_value(row["ZBOARDMANUALPLAYBACKOPTIONRAWVALUE"], "untilPlaylistEnds"),
            "boardAutoplaySkipWeekends": bool_value(row["ZBOARDAUTOPLAYSKIPWEEKENDS"]),
            "boardAutoplaySkipChinaHolidays": bool_value(row["ZBOARDAUTOPLAYSKIPCHINAHOLIDAYS"]),
            "aiSummaryEnabled": bool_value(row["ZAISUMMARYENABLED"]),
            "aiSummaryModelRawValue": text_value(row["ZAISUMMARYMODELRAWVALUE"], "deepseek-chat"),
        }

    return {
        "version": 4,
        "exportedAt": datetime.now(timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z"),
        "appVersion": "sqlite-migration",
        "settings": settings,
        "reviewItems": map_rows(connection, "ZREVIEWITEM", lambda r: {
            "id": uuid_value(r["ZID"]), "typeRawValue": text_value(r["ZTYPERAWVALUE"]),
            "content": text_value(r["ZCONTENT"]), "prompt": text_value(r["ZPROMPT"]),
            "note": text_value(r["ZNOTE"]), "source": text_value(r["ZSOURCE"]),
            "stage": r["ZSTAGE"], "nextReviewAt": date_value(r["ZNEXTREVIEWAT"]),
            "lastReviewedAt": date_value(r["ZLASTREVIEWEDAT"]),
            "consecutiveCorrectCount": r["ZCONSECUTIVECORRECTCOUNT"],
            "consecutiveWrongCount": r["ZCONSECUTIVEWRONGCOUNT"],
            "isPriority": bool_value(r["ZISPRIORITY"]),
            "reviewTrackRawValue": r["ZREVIEWTRACKRAWVALUE"],
            "dictationFollowUpStep": r["ZDICTATIONFOLLOWUPSTEP"],
            "isDictationPassRaw": None if r["ZISDICTATIONPASSRAW"] is None else bool_value(r["ZISDICTATIONPASSRAW"]),
            "createdAt": date_value(r["ZCREATEDAT"]), "updatedAt": date_value(r["ZUPDATEDAT"]),
        }),
        "reviewRecords": map_rows(connection, "ZREVIEWRECORD", lambda r: {
            "id": uuid_value(r["ZID"]), "itemID": uuid_value(r["ZITEMID"]),
            "reviewedAt": date_value(r["ZREVIEWEDAT"]), "resultRawValue": text_value(r["ZRESULTRAWVALUE"]),
            "modeRawValue": text_value(r["ZMODERAWVALUE"]), "oldStage": r["ZOLDSTAGE"],
            "newStage": r["ZNEWSTAGE"], "note": text_value(r["ZNOTE"]),
        }),
        "taskItems": map_rows(connection, "ZTASKITEM", lambda r: {
            "id": uuid_value(r["ZID"]), "title": text_value(r["ZTITLE"]), "note": text_value(r["ZNOTE"]),
            "recurrenceJSON": r["ZRECURRENCEJSON"], "skipPolicyRawValue": r["ZSKIPPOLICYRAWVALUE"],
            "startDate": date_value(r["ZSTARTDATE"]), "endDate": date_value(r["ZENDDATE"]),
            "pauseIntervalsJSON": r["ZPAUSEINTERVALSJSON"], "pauseStartedAt": date_value(r["ZPAUSESTARTEDAT"]),
            "isArchived": bool_value(r["ZISARCHIVED"]), "createdAt": date_value(r["ZCREATEDAT"]),
            "updatedAt": date_value(r["ZUPDATEDAT"]),
        }),
        "taskCompletions": map_rows(connection, "ZTASKCOMPLETION", lambda r: {
            "id": uuid_value(r["ZID"]), "taskID": uuid_value(r["ZTASKID"]),
            "completedDate": date_value(r["ZCOMPLETEDDATE"]), "completedAt": date_value(r["ZCOMPLETEDAT"]),
        }),
        "taskSubitems": map_rows(connection, "ZTASKSUBITEM", lambda r: {
            "id": uuid_value(r["ZID"]), "parentTaskID": uuid_value(r["ZPARENTTASKID"]),
            "taskExecutionIDRawValue": text_value(r["ZTASKEXECUTIONIDRAWVALUE"]),
            "title": text_value(r["ZTITLE"]), "note": text_value(r["ZNOTE"]), "detail": text_value(r["ZDETAIL"]),
            "statusRawValue": text_value(r["ZSTATUSRAWVALUE"], "pending"), "sortOrder": r["ZSORTORDER"],
            "isArchived": bool_value(r["ZISARCHIVED"]), "completedAt": date_value(r["ZCOMPLETEDAT"]),
            "createdAt": date_value(r["ZCREATEDAT"]), "updatedAt": date_value(r["ZUPDATEDAT"]),
        }),
        "taskExecutionRecords": map_rows(connection, "ZTASKEXECUTIONRECORD", lambda r: {
            "id": uuid_value(r["ZID"]), "taskID": uuid_value(r["ZTASKID"]),
            "occurrenceDate": date_value(r["ZOCCURRENCEDATE"]), "detail": text_value(r["ZDETAIL"]),
            "statusRawValue": text_value(r["ZSTATUSRAWVALUE"], "pending"), "completedAt": date_value(r["ZCOMPLETEDAT"]),
            "createdAt": date_value(r["ZCREATEDAT"]), "updatedAt": date_value(r["ZUPDATEDAT"]),
        }),
        "taskSubitemExecutionRecords": map_rows(connection, "ZTASKSUBITEMEXECUTIONRECORD", lambda r: {
            "id": uuid_value(r["ZID"]), "taskExecutionID": uuid_value(r["ZTASKEXECUTIONID"]),
            "subtaskID": uuid_value(r["ZSUBTASKID"]), "detail": text_value(r["ZDETAIL"]),
            "statusRawValue": text_value(r["ZSTATUSRAWVALUE"], "pending"), "completedAt": date_value(r["ZCOMPLETEDAT"]),
            "createdAt": date_value(r["ZCREATEDAT"]), "updatedAt": date_value(r["ZUPDATEDAT"]),
        }),
        "dictationSessions": map_rows(connection, "ZDICTATIONSESSION", lambda r: {
            "id": uuid_value(r["ZID"]), "title": text_value(r["ZTITLE"]),
            "typeRawValue": text_value(r["ZTYPERAWVALUE"]), "createdAt": date_value(r["ZCREATEDAT"]),
            "updatedAt": date_value(r["ZUPDATEDAT"]), "scheduledDate": date_value(r["ZSCHEDULEDDATE"]),
            "finishedAt": date_value(r["ZFINISHEDAT"]), "reviewedAt": date_value(r["ZREVIEWEDAT"]),
        }),
        "dictationEntries": map_rows(connection, "ZDICTATIONENTRY", lambda r: {
            "id": uuid_value(r["ZID"]), "sessionID": uuid_value(r["ZSESSIONID"]), "sortOrder": r["ZSORTORDER"],
            "typeRawValue": text_value(r["ZTYPERAWVALUE"]), "content": text_value(r["ZCONTENT"]),
            "prompt": text_value(r["ZPROMPT"]), "note": text_value(r["ZNOTE"]), "source": text_value(r["ZSOURCE"]),
            "resultRawValue": text_value(r["ZRESULTRAWVALUE"], "pending"),
            "createdAt": date_value(r["ZCREATEDAT"]), "updatedAt": date_value(r["ZUPDATEDAT"]),
        }),
        "scheduleItems": map_rows(connection, "ZSCHEDULEITEM", lambda r: {
            "id": uuid_value(r["ZID"]), "title": text_value(r["ZTITLE"]), "note": text_value(r["ZNOTE"]),
            "startTime": date_value(r["ZSTARTTIME"]), "endTime": date_value(r["ZENDTIME"]),
            "repeatRuleRawValue": text_value(r["ZREPEATRULERAWVALUE"], "once"),
            "weekdaysJSON": text_value(r["ZWEEKDAYSJSON"], "[]"),
            "effectiveStartDate": date_value(r["ZEFFECTIVESTARTDATE"]),
            "effectiveEndDate": date_value(r["ZEFFECTIVEENDDATE"]), "isArchived": bool_value(r["ZISARCHIVED"]),
            "createdAt": date_value(r["ZCREATEDAT"]), "updatedAt": date_value(r["ZUPDATEDAT"]),
        }),
        "mediaAssets": [],
        "pointLedgerEntries": map_rows(connection, "ZPOINTLEDGERENTRY", lambda r: {
            "id": uuid_value(r["ZID"]), "createdAt": date_value(r["ZCREATEDAT"]), "amount": r["ZAMOUNT"],
            "kindRawValue": text_value(r["ZKINDRAWVALUE"], "reward"),
            "sourceTypeRawValue": text_value(r["ZSOURCETYPERAWVALUE"], "reviewRecord"),
            "sourceIDRawValue": text_value(r["ZSOURCEIDRAWVALUE"]),
            "idempotencyKey": text_value(r["ZIDEMPOTENCYKEY"]), "note": text_value(r["ZNOTE"]),
            "isReversal": bool_value(r["ZISREVERSAL"]), "reversesEntryIDRawValue": r["ZREVERSESENTRYIDRAWVALUE"],
        }),
        "pointRewardStates": map_rows(connection, "ZPOINTREWARDSTATE", lambda r: {
            "id": uuid_value(r["ZID"]), "currentStreak": r["ZCURRENTSTREAK"],
            "lastActiveDay": date_value(r["ZLASTACTIVEDAY"]), "longestStreak": r["ZLONGESTSTREAK"],
            "updatedAt": date_value(r["ZUPDATEDAT"]),
        }),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--store", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix="typo-review-export-") as temp_dir:
        snapshot_path = Path(temp_dir) / "snapshot.store"
        source = sqlite3.connect(f"file:{arguments.store}?mode=ro", uri=True)
        destination = sqlite3.connect(snapshot_path)
        source.backup(destination)
        source.close()
        destination.row_factory = sqlite3.Row
        payload = make_payload(destination)
        destination.close()

    arguments.output.write_text(
        json.dumps(payload, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )
    counts = {
        key: len(value)
        for key, value in payload.items()
        if isinstance(value, list)
    }
    print(json.dumps({"output": str(arguments.output), "counts": counts}, ensure_ascii=False))


if __name__ == "__main__":
    main()
