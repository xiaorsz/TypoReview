import unittest
import sys
from datetime import datetime, timezone
from types import SimpleNamespace
from uuid import UUID, uuid4

# The repository's lightweight unit-test command does not install the production
# PostgreSQL driver. The helper under test only needs the connection protocol,
# which is provided by FakeConnection below.
try:
    import asyncpg  # noqa: F401
except ModuleNotFoundError:
    sys.modules["asyncpg"] = SimpleNamespace(Connection=object, Pool=object)

from app.db import upsert_point_ledger_entry


ACCOUNT_ID = UUID("00000000-0000-0000-0000-000000000001")


class FakeConnection:
    def __init__(self, *, inserted_id=None, existing=None, execute_status="UPDATE 1"):
        self.inserted_id = inserted_id
        self.existing = existing
        self.execute_status = execute_status
        self.fetchval_calls = []
        self.fetchrow_calls = []
        self.execute_calls = []

    async def fetchval(self, query, *args):
        self.fetchval_calls.append((query, args))
        return self.inserted_id

    async def fetchrow(self, query, *args):
        self.fetchrow_calls.append((query, args))
        return self.existing

    async def execute(self, query, *args):
        self.execute_calls.append((query, args))
        return self.execute_status


def point_payload(record_id, key):
    return {
        "id": str(record_id),
        "idempotencyKey": key,
        "amount": 1,
        "createdAt": "2026-07-24T12:00:00Z",
    }


class PointLedgerUpsertTests(unittest.IsolatedAsyncioTestCase):
    async def test_new_logical_award_is_inserted(self):
        record_id = uuid4()
        connection = FakeConnection(inserted_id=record_id)

        changed, duplicate = await upsert_point_ledger_entry(
            connection,
            account_id=ACCOUNT_ID,
            record_id=record_id,
            payload=point_payload(record_id, "dictation-entry-1"),
            client_updated_at=datetime(2026, 7, 24, 12, tzinfo=timezone.utc),
        )

        self.assertTrue(changed)
        self.assertFalse(duplicate)
        self.assertEqual(len(connection.fetchval_calls), 1)
        self.assertEqual(connection.fetchrow_calls, [])
        self.assertEqual(connection.execute_calls, [])

    async def test_same_idempotency_key_with_different_uuid_is_acknowledged(self):
        canonical_id = uuid4()
        duplicate_id = uuid4()
        key = "dictation-entry-shared"
        connection = FakeConnection(
            inserted_id=None,
            existing={
                "record_id": canonical_id,
                "payload": point_payload(canonical_id, key),
                "deleted_at": None,
            },
        )

        changed, duplicate = await upsert_point_ledger_entry(
            connection,
            account_id=ACCOUNT_ID,
            record_id=duplicate_id,
            payload=point_payload(duplicate_id, key),
            client_updated_at=datetime(2026, 7, 24, 12, tzinfo=timezone.utc),
        )

        self.assertFalse(changed)
        self.assertTrue(duplicate)
        self.assertEqual(len(connection.fetchrow_calls), 1)
        self.assertEqual(connection.execute_calls, [])

    async def test_existing_record_uuid_can_still_be_updated(self):
        record_id = uuid4()
        key = "dictation-entry-existing"
        connection = FakeConnection(
            inserted_id=None,
            existing={
                "record_id": record_id,
                "payload": point_payload(record_id, key),
                "deleted_at": None,
            },
        )

        changed, duplicate = await upsert_point_ledger_entry(
            connection,
            account_id=ACCOUNT_ID,
            record_id=record_id,
            payload=point_payload(record_id, key),
            client_updated_at=datetime(2026, 7, 24, 12, tzinfo=timezone.utc),
        )

        self.assertTrue(changed)
        self.assertFalse(duplicate)
        self.assertEqual(len(connection.execute_calls), 1)
