from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any
from uuid import UUID

import asyncpg

from .domain import parse_datetime

SCHEMA_PATH = Path(__file__).with_name("schema.sql")


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

    async def close(self) -> None:
        if self.pool is not None:
            await self.pool.close()
            self.pool = None

    def require_pool(self) -> asyncpg.Pool:
        if self.pool is None:
            raise RuntimeError("database is not connected")
        return self.pool


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
