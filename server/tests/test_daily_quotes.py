import sys
import unittest
from datetime import date
from types import SimpleNamespace

try:
    import asyncpg  # noqa: F401
except ModuleNotFoundError:
    sys.modules["asyncpg"] = SimpleNamespace(Connection=object, Pool=object)

from app.db import fetch_or_assign_daily_quote, load_seed_daily_quotes


class QueueConnection:
    def __init__(self, *, rows, values=()):
        self.rows = list(rows)
        self.values = list(values)
        self.fetchrow_calls = []
        self.fetchval_calls = []

    async def fetchrow(self, query, *args):
        self.fetchrow_calls.append((query, args))
        return self.rows.pop(0)

    async def fetchval(self, query, *args):
        self.fetchval_calls.append((query, args))
        return self.values.pop(0)


class DailyQuoteSeedTests(unittest.TestCase):
    def test_initial_library_has_110_complete_unique_entries(self):
        quotes = load_seed_daily_quotes()

        self.assertEqual(len(quotes), 110)
        self.assertEqual(len({quote["id"] for quote in quotes}), 110)
        self.assertEqual(len({quote["sortOrder"] for quote in quotes}), 110)
        self.assertEqual(len({quote["text"] for quote in quotes}), 110)
        self.assertTrue(all(quote["text"] for quote in quotes))
        self.assertTrue(all(quote["attribution"] for quote in quotes if quote["kind"] == "verified"))
        self.assertTrue(all(quote["explanation"] for quote in quotes))
        self.assertTrue(all(quote["action"] for quote in quotes))


class DailyQuoteAssignmentTests(unittest.IsolatedAsyncioTestCase):
    async def test_existing_day_returns_the_same_assignment(self):
        existing = {"id": "classic-001", "quote_text": "今天的句子"}
        connection = QueueConnection(rows=[existing])

        result = await fetch_or_assign_daily_quote(
            connection,
            quote_day=date(2026, 7, 31),
        )

        self.assertEqual(result, existing)
        self.assertEqual(len(connection.fetchrow_calls), 1)
        self.assertEqual(connection.fetchval_calls, [])

    async def test_empty_library_returns_exhausted(self):
        connection = QueueConnection(rows=[None, None])

        result = await fetch_or_assign_daily_quote(
            connection,
            quote_day=date(2026, 11, 18),
        )

        self.assertIsNone(result)
        self.assertEqual(len(connection.fetchrow_calls), 2)
        self.assertEqual(connection.fetchval_calls, [])

    async def test_new_day_assigns_next_unused_quote(self):
        assigned = {
            "id": "classic-002",
            "quote_text": "新的一句",
            "kind": "verified",
            "attribution": "出处",
            "explanation": "解释",
            "action_text": "行动",
        }
        connection = QueueConnection(
            rows=[None, {"id": "classic-002"}, assigned],
            values=["classic-002"],
        )

        result = await fetch_or_assign_daily_quote(
            connection,
            quote_day=date(2026, 8, 1),
        )

        self.assertEqual(result, assigned)
        self.assertEqual(len(connection.fetchval_calls), 1)
        self.assertEqual(connection.fetchval_calls[0][1], (date(2026, 8, 1), "classic-002"))
