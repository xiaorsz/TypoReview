"""Set TYPO_SYNC_TEST_DATABASE_URL to an isolated typo_sync_regression database."""
import asyncio
import os
import unittest
from datetime import datetime, timezone
from urllib.parse import urlparse
from uuid import uuid4

DSN = os.environ.get("TYPO_SYNC_TEST_DATABASE_URL")

@unittest.skipUnless(DSN, "requires disposable PostgreSQL")
class SyncIntegrationTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        if urlparse(DSN).path != "/typo_sync_regression":
            raise RuntimeError("Only the disposable typo_sync_regression database is allowed")
        from app import main
        from app.db import upsert_record
        self.api, self.upsert = main, upsert_record
        self.old_dsn = os.environ.get("DATABASE_URL")
        os.environ["DATABASE_URL"] = DSN
        await main.database.connect()
        self.account, self.now = uuid4(), datetime(2026, 9, 11, 2, tzinfo=timezone.utc)
        async with main.database.require_pool().acquire() as c:
            await c.execute("INSERT INTO accounts(id) VALUES($1)", self.account)

    async def asyncTearDown(self):
        async with self.api.database.require_pool().acquire() as c:
            await c.execute("DELETE FROM accounts WHERE id=$1", self.account)
        await self.api.database.close()
        if self.old_dsn is None: os.environ.pop("DATABASE_URL", None)
        else: os.environ["DATABASE_URL"] = self.old_dsn

    def mutation(self, entity="taskItems", record=None, payload=None, **kwargs):
        record = record or uuid4()
        return self.api.Mutation(mutationID=uuid4(), entityType=entity, recordID=record,
            operation=kwargs.pop("operation", "upsert"), updatedAt=self.now,
            payload=payload or {"id": str(record), "title": "test"}, **kwargs)

    async def push(self, mutations, cursor=None):
        return await self.api.push_mutations(self.api.MutationBatch(
            mutations=mutations, baseCursor=cursor, isolateConflicts=True), self.account)

    async def test_sequence_follows_commit_order_for_direct_writes(self):
        pool = self.api.database.require_pool()
        started = asyncio.Event()
        async with pool.acquire() as first:
            async with first.transaction():
                await self.upsert(first, account_id=self.account, entity_type="taskItems", record_id=uuid4(),
                                  payload={"title": "first"}, client_updated_at=self.now)
                async def writer():
                    async with pool.acquire() as second, second.transaction():
                        started.set()
                        await self.upsert(second, account_id=self.account, entity_type="taskItems", record_id=uuid4(),
                                          payload={"title": "second"}, client_updated_at=self.now)
                pending = asyncio.create_task(writer())
                await started.wait()
                await asyncio.sleep(.05)
                self.assertFalse(pending.done())
                visible = await self.api.changes(after=0, limit=100, account_id=self.account)
                self.assertEqual(visible["changes"], [])
            await asyncio.wait_for(pending, 3)
        result = await self.api.changes(after=0, limit=100, account_id=self.account)
        self.assertEqual([r["payload"]["title"] for r in result["changes"]], ["first", "second"])

    async def test_parallel_conflict_checks_cannot_both_overwrite(self):
        from fastapi import HTTPException
        record = uuid4()
        a = self.mutation(record=record, payload={"title": "A"})
        b = self.mutation(record=record, payload={"title": "B"})
        results = await asyncio.gather(self.push([a], 0), self.push([b], 0), return_exceptions=True)
        self.assertEqual(sum(isinstance(r, HTTPException) and r.status_code == 409 for r in results), 1)
        self.assertEqual(sum(isinstance(r, dict) for r in results), 1)

    async def test_delete_unknown_record_prevents_resurrection(self):
        record = uuid4()
        await self.push([self.mutation(record=record, operation="delete", deletionIntent="explicit")], 0)
        stale = self.mutation(record=record)
        response = await self.push([stale], 0)
        self.assertIn(str(stale.mutationID), response["appliedMutationIDs"])
        result = await self.api.changes(after=0, limit=100, account_id=self.account)
        self.assertIsNotNone(result["changes"][0]["deletedAt"])

    async def test_acknowledged_request_retry_after_later_edits(self):
        first = self.mutation()
        await self.push([first], 0)
        await self.push([self.mutation(record=first.recordID, payload={"title": "new"})])
        result = await self.push([first], 0)
        self.assertEqual(result["appliedMutationIDs"], [str(first.mutationID)])
        rows = await self.api.changes(after=0, limit=100, account_id=self.account)
        self.assertEqual(rows["changes"][0]["payload"]["title"], "new")

    async def seed_review(self):
        item = uuid4()
        await self.push([self.mutation("reviewItems", item, {
            "id": str(item), "stage": 0, "nextReviewAt": "2026-09-10T00:00:00Z",
            "consecutiveCorrectCount": 0, "consecutiveWrongCount": 0,
            "reviewTrackRawValue": "standard", "isDictationPassRaw": False,
        })])
        await self.api.daily_plan(self.api.DailyPlanRequest(day=self.now.date(), dailyLimit=10), self.account)
        record = self.mutation("reviewRecords", payload={"itemID": str(item).upper(), "resultRawValue": "correct",
                                "modeRawValue": "scheduled", "reviewedAt": self.now.isoformat()})
        await self.push([record])
        return item, record

    async def test_same_day_duplicate_converges_to_one_event(self):
        _, first = await self.seed_review()
        result = await self.push([self.mutation("reviewRecords", payload=first.payload)])
        self.assertEqual(result["conflicts"], [])
        rows = await self.api.changes(after=0, limit=100, account_id=self.account)
        active = [r for r in rows["changes"] if r["entityType"] == "reviewRecords" and r["deletedAt"] is None]
        self.assertEqual(len(active), 1)
        self.assertEqual(active[0]["recordID"], str(first.recordID))

    async def test_conflict_isolates_dependent_progress_but_not_other_records(self):
        item, first = await self.seed_review()
        conflicting = self.mutation("reviewRecords", payload={**first.payload, "resultRawValue": "wrong"})
        dependent = self.mutation("reviewItems", item, {"id": str(item), "stage": 0})
        unrelated = self.mutation()
        result = await self.push([conflicting, dependent, unrelated])
        self.assertEqual(result["appliedMutationIDs"], [str(unrelated.mutationID)])
        self.assertEqual(len(result["conflicts"]), 2)
        async with self.api.database.require_pool().acquire() as c:
            count = await c.fetchval("SELECT count(*) FROM processed_mutations WHERE account_id=$1 AND mutation_id=$2",
                                     self.account, conflicting.mutationID)
        self.assertEqual(count, 0)

    async def test_review_deletion_reopens_daily_plan(self):
        _, first = await self.seed_review()
        await self.push([self.mutation("reviewRecords", first.recordID, operation="delete", deletionIntent="explicit")])
        plan = await self.api.daily_plan(self.api.DailyPlanRequest(day=self.now.date(), dailyLimit=10), self.account)
        self.assertIsNone(plan["items"][0]["completedEventID"])

    async def test_manifest_matches_change_stream(self):
        await self.push([self.mutation(), self.mutation()])
        manifest = await self.api.sync_manifest(self.account)
        changes = await self.api.changes(after=0, limit=100, account_id=self.account)
        self.assertEqual(manifest["protocolVersion"], 2)
        self.assertEqual(manifest["cursor"], changes["cursor"])
        self.assertEqual(len(manifest["records"]), 2)
