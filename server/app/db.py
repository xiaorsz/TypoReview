from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any
from uuid import UUID

import asyncpg

from .domain import parse_datetime

SCHEMA_PATH = Path(__file__).with_name("schema.sql")
DAILY_QUOTES_PATH = Path(__file__).with_name("daily_quotes.json")


class Database:
    def __init__(self) -> None:
        self.pool: asyncpg.Pool | None = None

    async def connect(self) -> None:
        async def configure_connection(connection: asyncpg.Connection) -> None:
            await connection.set_type_codec(
                "jsonb",
                schema="pg_catalog",
                encoder=lambda value: json.dumps(value, ensure_ascii=False),
                decoder=json.loads,
                format="text",
            )

        self.pool = await asyncpg.create_pool(
            os.environ["DATABASE_URL"],
            min_size=1,
            max_size=8,
            command_timeout=30,
            init=configure_connection,
        )
        async with self.pool.acquire() as connection:
            await connection.execute(SCHEMA_PATH.read_text())
            account_id = UUID(os.environ.get("DEFAULT_ACCOUNT_ID", "00000000-0000-0000-0000-000000000001"))
            await connection.execute(
                "INSERT INTO accounts(id) VALUES($1) ON CONFLICT (id) DO NOTHING",
                account_id,
            )
            await seed_daily_quotes(connection)

    async def close(self) -> None:
        if self.pool is not None:
            await self.pool.close()
            self.pool = None

    def require_pool(self) -> asyncpg.Pool:
        if self.pool is None:
            raise RuntimeError("database is not connected")
        return self.pool


def load_seed_daily_quotes() -> list[dict[str, Any]]:
    if not DAILY_QUOTES_PATH.exists():
        return []
    payload = json.loads(DAILY_QUOTES_PATH.read_text(encoding="utf-8"))
    quotes = payload.get("quotes", [])
    if not isinstance(quotes, list):
        raise ValueError("daily_quotes.json must contain a quotes array")

    seen_ids: set[str] = set()
    seen_texts: set[str] = set()
    seen_orders: set[int] = set()
    normalized: list[dict[str, Any]] = []
    for raw in quotes:
        if not isinstance(raw, dict):
            raise ValueError("every daily quote must be an object")
        quote_id = str(raw.get("id") or "").strip()
        text = str(raw.get("text") or "").strip()
        attribution = str(raw.get("attribution") or "").strip()
        explanation = str(raw.get("explanation") or "").strip()
        action = str(raw.get("action") or "").strip()
        kind = str(raw.get("kind") or "verified").strip()
        sort_order = raw.get("sortOrder")
        if not quote_id or not text or not explanation or not action:
            raise ValueError(f"daily quote {quote_id or '<missing id>'} has incomplete content")
        if kind not in {"verified", "encouragement"}:
            raise ValueError(f"daily quote {quote_id} has an invalid kind")
        if kind == "verified" and not attribution:
            raise ValueError(f"verified daily quote {quote_id} is missing attribution")
        if not isinstance(sort_order, int) or sort_order < 0:
            raise ValueError(f"daily quote {quote_id} has an invalid sortOrder")
        if quote_id in seen_ids or text in seen_texts or sort_order in seen_orders:
            raise ValueError(f"daily quote {quote_id} has a duplicate id, text, or sortOrder")
        seen_ids.add(quote_id)
        seen_texts.add(text)
        seen_orders.add(sort_order)
        normalized.append(
            {
                "id": quote_id,
                "text": text,
                "kind": kind,
                "attribution": attribution,
                "explanation": explanation,
                "action": action,
                "sortOrder": sort_order,
            }
        )
    return normalized


async def seed_daily_quotes(connection: asyncpg.Connection) -> None:
    for quote in load_seed_daily_quotes():
        await connection.execute(
            """
            INSERT INTO daily_quotes(
                id, quote_text, kind, attribution, explanation, action_text, sort_order
            )
            VALUES($1,$2,$3,$4,$5,$6,$7)
            ON CONFLICT (id) DO NOTHING
            """,
            quote["id"],
            quote["text"],
            quote["kind"],
            quote["attribution"],
            quote["explanation"],
            quote["action"],
            quote["sortOrder"],
        )


async def fetch_or_assign_daily_quote(
    connection: asyncpg.Connection,
    *,
    quote_day: Any,
) -> Any:
    existing = await connection.fetchrow(
        """
        SELECT q.id, q.quote_text, q.kind, q.attribution, q.explanation, q.action_text
        FROM daily_quote_assignments a
        JOIN daily_quotes q ON q.id=a.quote_id
        WHERE a.quote_day=$1
        """,
        quote_day,
    )
    if existing is not None:
        return existing

    candidate = await connection.fetchrow(
        """
        SELECT q.id
        FROM daily_quotes q
        WHERE q.is_active
          AND NOT EXISTS (
              SELECT 1 FROM daily_quote_assignments a WHERE a.quote_id=q.id
          )
        ORDER BY q.sort_order, q.id
        FOR UPDATE SKIP LOCKED
        LIMIT 1
        """
    )
    if candidate is None:
        return None

    inserted_quote_id = await connection.fetchval(
        """
        INSERT INTO daily_quote_assignments(quote_day, quote_id)
        VALUES($1,$2)
        ON CONFLICT (quote_day) DO NOTHING
        RETURNING quote_id
        """,
        quote_day,
        candidate["id"],
    )
    if inserted_quote_id is None:
        return await connection.fetchrow(
            """
            SELECT q.id, q.quote_text, q.kind, q.attribution, q.explanation, q.action_text
            FROM daily_quote_assignments a
            JOIN daily_quotes q ON q.id=a.quote_id
            WHERE a.quote_day=$1
            """,
            quote_day,
        )
    return await connection.fetchrow(
        """
        SELECT id, quote_text, kind, attribution, explanation, action_text
        FROM daily_quotes
        WHERE id=$1
        """,
        inserted_quote_id,
    )


async def upsert_record(
    connection: asyncpg.Connection,
    *,
    account_id: UUID,
    entity_type: str,
    record_id: UUID,
    payload: dict[str, Any],
    client_updated_at: Any,
) -> bool:
    updated_at = parse_datetime(client_updated_at)
    if updated_at is None:
        raise ValueError(f"{entity_type}/{record_id} is missing an update timestamp")
    status = await connection.execute(
        """
        INSERT INTO records(account_id, entity_type, record_id, payload, client_updated_at, deleted_at)
        VALUES($1, $2, $3, $4::jsonb, $5, NULL)
        ON CONFLICT (account_id, entity_type, record_id) DO UPDATE
        SET payload = EXCLUDED.payload,
            client_updated_at = EXCLUDED.client_updated_at,
            deleted_at = NULL
        WHERE EXCLUDED.client_updated_at >= records.client_updated_at
          AND (records.payload IS DISTINCT FROM EXCLUDED.payload OR records.deleted_at IS NOT NULL)
        """,
        account_id,
        entity_type,
        record_id,
        payload,
        updated_at,
    )
    return status.endswith("1")


async def upsert_point_ledger_entry(
    connection: asyncpg.Connection,
    *,
    account_id: UUID,
    record_id: UUID,
    payload: dict[str, Any],
    client_updated_at: Any,
) -> tuple[bool, bool]:
    """Insert one logical point award without failing on a duplicate device copy.

    Different devices can materialize the same idempotent award with different
    record UUIDs. The partial unique index correctly treats those rows as one
    logical award, so retain the first canonical row and acknowledge later
    duplicates instead of aborting the caller's whole sync transaction.
    """
    updated_at = parse_datetime(client_updated_at)
    if updated_at is None:
        raise ValueError(f"pointLedgerEntries/{record_id} is missing an update timestamp")

    idempotency_key = str(payload.get("idempotencyKey") or "").strip()
    if not idempotency_key:
        changed = await upsert_record(
            connection,
            account_id=account_id,
            entity_type="pointLedgerEntries",
            record_id=record_id,
            payload=payload,
            client_updated_at=updated_at,
        )
        return changed, False

    inserted_id = await connection.fetchval(
        """
        INSERT INTO records(account_id, entity_type, record_id, payload, client_updated_at, deleted_at)
        VALUES($1, 'pointLedgerEntries', $2, $3::jsonb, $4, NULL)
        ON CONFLICT DO NOTHING
        RETURNING record_id
        """,
        account_id,
        record_id,
        payload,
        updated_at,
    )
    if inserted_id is not None:
        return True, False

    # ON CONFLICT DO NOTHING also covers a concurrent insert. Once it returns,
    # the conflicting transaction is visible, so resolve which logical row won.
    existing = await connection.fetchrow(
        """
        SELECT record_id, payload, deleted_at
        FROM records
        WHERE account_id=$1
          AND entity_type='pointLedgerEntries'
          AND (
              record_id=$2
              OR (deleted_at IS NULL AND payload->>'idempotencyKey'=$3)
          )
        ORDER BY
          CASE
            WHEN deleted_at IS NULL AND payload->>'idempotencyKey'=$3 THEN 0
            ELSE 1
          END,
          client_updated_at,
          record_id
        LIMIT 1
        FOR UPDATE
        """,
        account_id,
        record_id,
        idempotency_key,
    )
    if existing is None:
        # A conflicting row was removed between statements. Retry once through
        # the normal insert path; a new conflict remains safely idempotent.
        return await upsert_point_ledger_entry(
            connection,
            account_id=account_id,
            record_id=record_id,
            payload=payload,
            client_updated_at=updated_at,
        )

    existing_payload = existing["payload"]
    existing_key = str(existing_payload.get("idempotencyKey") or "").strip()
    if existing["deleted_at"] is None and existing_key == idempotency_key:
        if existing["record_id"] != record_id:
            return False, True

    changed = await upsert_record(
        connection,
        account_id=account_id,
        entity_type="pointLedgerEntries",
        record_id=record_id,
        payload=payload,
        client_updated_at=updated_at,
    )
    return changed, False


async def tombstone_record(
    connection: asyncpg.Connection,
    *,
    account_id: UUID,
    entity_type: str,
    record_id: UUID,
    deleted_at: Any,
) -> None:
    timestamp = parse_datetime(deleted_at)
    if timestamp is None:
        raise ValueError("deleted_at is required")
    await connection.execute(
        """
        UPDATE records
        SET deleted_at = $4, client_updated_at = $4
        WHERE account_id = $1 AND entity_type = $2 AND record_id = $3
          AND client_updated_at <= $4
        """,
        account_id,
        entity_type,
        record_id,
        timestamp,
    )
