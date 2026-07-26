from __future__ import annotations

from datetime import date, datetime, time, timedelta, timezone
from typing import Any, Iterable
from uuid import UUID
from zoneinfo import ZoneInfo

SHANGHAI = ZoneInfo("Asia/Shanghai")
INTERVALS = [0, 1, 2, 4, 7, 15, 30]
COMPLETION_STAGE = 7
DICTATION_FOLLOW_UP_COMPLETE_STAGE = 6
SETTINGS_RECORD_ID = UUID("00000000-0000-0000-0000-000000000002")

ENTITY_KEYS = (
    "reviewItems",
    "reviewRecords",
    "taskItems",
    "taskCompletions",
    "taskSubitems",
    "taskExecutionRecords",
    "taskSubitemExecutionRecords",
    "dictationSessions",
    "dictationEntries",
    "scheduleItems",
    "pointLedgerEntries",
    "pointRewardStates",
)


def canonicalize_settings(payload: dict[str, Any]) -> dict[str, Any]:
    return {**payload, "id": str(SETTINGS_RECORD_ID)}


def parse_datetime(value: str | datetime | None) -> datetime | None:
    if value is None:
        return None
    if isinstance(value, datetime):
        parsed = value
    else:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def isoformat(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def day_start(value: datetime, days: int = 0) -> datetime:
    local = value.astimezone(SHANGHAI).date() + timedelta(days=days)
    return datetime.combine(local, time.min, SHANGHAI).astimezone(timezone.utc)


def next_review_date(stage: int, reviewed_at: datetime) -> datetime:
    safe_stage = max(0, min(stage, len(INTERVALS) - 1))
    candidate = day_start(reviewed_at, INTERVALS[safe_stage])
    if candidate == day_start(reviewed_at):
        return day_start(reviewed_at, 1)
    return candidate


def is_due(payload: dict[str, Any], plan_day: date) -> bool:
    next_review_at = parse_datetime(payload.get("nextReviewAt"))
    if next_review_at is None or next_review_at.year >= 4000:
        return False
    return next_review_at.astimezone(SHANGHAI).date() <= plan_day


def apply_review_result(
    item: dict[str, Any],
    *,
    result: str,
    reviewed_at: datetime,
) -> tuple[dict[str, Any], int, int]:
    updated = dict(item)
    old_stage = int(updated.get("stage", 0))
    current_stage = old_stage
    correct_count = int(updated.get("consecutiveCorrectCount", 0))
    wrong_count = int(updated.get("consecutiveWrongCount", 0))
    track = updated.get("reviewTrackRawValue") or "standard"
    is_dictation_pass = bool(updated.get("isDictationPassRaw", False))

    if track == "dictationFollowUp" or is_dictation_pass:
        step = max(1, int(updated.get("dictationFollowUpStep") or 1))
        if result == "correct":
            correct_count += 1
            wrong_count = 0
            updated["isPriority"] = False
            if step <= 1:
                updated["reviewTrackRawValue"] = "dictationFollowUp"
                updated["dictationFollowUpStep"] = 2
                updated["isDictationPassRaw"] = True
                current_stage = max(current_stage, 2)
                updated["nextReviewAt"] = isoformat(day_start(reviewed_at, 4))
            else:
                current_stage = max(current_stage, DICTATION_FOLLOW_UP_COMPLETE_STAGE)
                updated["reviewTrackRawValue"] = "standard"
                updated["dictationFollowUpStep"] = 0
                updated["isDictationPassRaw"] = False
                updated["nextReviewAt"] = isoformat(next_review_date(current_stage, reviewed_at))
        else:
            updated["reviewTrackRawValue"] = "standard"
            updated["dictationFollowUpStep"] = 0
            updated["isDictationPassRaw"] = False
            correct_count = 0
            wrong_count += 1
            current_stage = 1
            updated["nextReviewAt"] = isoformat(day_start(reviewed_at, 1))
            updated["isPriority"] = True
    elif result == "correct":
        correct_count += 1
        wrong_count = 0
        current_stage = min(2 if current_stage <= 0 else current_stage + 1, COMPLETION_STAGE)
        updated["nextReviewAt"] = (
            "4001-01-01T00:00:00.000Z"
            if current_stage >= COMPLETION_STAGE
            else isoformat(next_review_date(current_stage, reviewed_at))
        )
        updated["isPriority"] = False
    else:
        correct_count = 0
        wrong_count += 1
        current_stage = max(current_stage - 1, 1)
        updated["nextReviewAt"] = isoformat(next_review_date(current_stage, reviewed_at))
        updated["isPriority"] = wrong_count >= 2

    updated["stage"] = current_stage
    updated["consecutiveCorrectCount"] = correct_count
    updated["consecutiveWrongCount"] = wrong_count
    updated["lastReviewedAt"] = isoformat(reviewed_at)
    updated["updatedAt"] = isoformat(reviewed_at)
    return updated, old_stage, current_stage


def unique_ids(values: Iterable[str | UUID]) -> list[UUID]:
    result: list[UUID] = []
    seen: set[UUID] = set()
    for value in values:
        parsed = value if isinstance(value, UUID) else UUID(str(value))
        if parsed not in seen:
            seen.add(parsed)
            result.append(parsed)
    return result
