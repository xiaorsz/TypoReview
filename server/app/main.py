from __future__ import annotations

import hashlib
import hmac
import json
import os
import secrets
from contextlib import asynccontextmanager
from datetime import date, datetime, timezone
from typing import Any, Literal
from uuid import UUID, uuid4

import asyncpg
from fastapi import Depends, FastAPI, Header, HTTPException, Query, Response, status
from pydantic import BaseModel, Field

from .db import (
    Database,
    lock_sync_writes,
    fetch_or_assign_daily_quote,
    record_has_changed_after,
    tombstone_record,
    upsert_point_ledger_entry,
    upsert_record,
)
from .domain import (
    ENTITY_KEYS,
    SETTINGS_RECORD_ID,
    SHANGHAI,
    apply_review_result,
    canonicalize_settings,
    is_due,
    isoformat,
    parse_datetime,
    should_apply_sync_delete,
    unique_ids,
)

database = Database()
DEFAULT_ACCOUNT_ID = UUID(os.environ.get("DEFAULT_ACCOUNT_ID", "00000000-0000-0000-0000-000000000001"))

UPDATED_AT_FIELD = {
    "reviewItems": "updatedAt",
    "reviewRecords": "reviewedAt",
    "taskItems": "updatedAt",
    "taskCompletions": "completedAt",
    "taskSubitems": "updatedAt",
    "taskExecutionRecords": "updatedAt",
    "taskSubitemExecutionRecords": "updatedAt",
    "dictationSessions": "updatedAt",
    "dictationEntries": "updatedAt",
    "scheduleItems": "updatedAt",
    "calculationRounds": "updatedAt",
    "pointLedgerEntries": "createdAt",
    "pointRewardStates": "updatedAt",
}


@asynccontextmanager
async def lifespan(_: FastAPI):
    await database.connect()
    yield
    await database.close()


app = FastAPI(
    title="TypoReview Sync API",
    version="1.0.0",
    lifespan=lifespan,
    docs_url=None,
    redoc_url=None,
)


async def require_account(authorization: str | None = Header(default=None)) -> UUID:
    expected = os.environ.get("API_TOKEN", "")
    if not expected:
        raise HTTPException(status_code=503, detail="API token is not configured")
    supplied = ""
    if authorization and authorization.startswith("Bearer "):
        supplied = authorization[7:]
    if hmac.compare_digest(supplied.encode(), expected.encode()):
        return DEFAULT_ACCOUNT_ID
    if supplied:
        token_hash = hashlib.sha256(supplied.encode()).hexdigest()
        pool = database.require_pool()
        async with pool.acquire() as connection:
            account_id = await connection.fetchval(
                """
                UPDATE device_tokens
                SET last_used_at=now()
                WHERE token_hash=$1 AND revoked_at IS NULL
                RETURNING account_id
                """,
                token_hash,
            )
        if account_id is not None:
            return account_id
    raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="invalid API token")


async def require_master_token(authorization: str | None = Header(default=None)) -> UUID:
    expected = os.environ.get("API_TOKEN", "")
    supplied = authorization[7:] if authorization and authorization.startswith("Bearer ") else ""
    if not expected or not hmac.compare_digest(supplied.encode(), expected.encode()):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="master token required")
    return DEFAULT_ACCOUNT_ID


def pairing_code_hash(value: str) -> str:
    normalized = "".join(character for character in value.upper() if character.isalnum())
    return hashlib.sha256(normalized.encode()).hexdigest()


class SnapshotImport(BaseModel):
    version: int = 5
    exportedAt: datetime
    appVersion: str = "unknown"
    settings: dict[str, Any] | None = None
    reviewItems: list[dict[str, Any]] = Field(default_factory=list)
    reviewRecords: list[dict[str, Any]] = Field(default_factory=list)
    taskItems: list[dict[str, Any]] = Field(default_factory=list)
    taskCompletions: list[dict[str, Any]] = Field(default_factory=list)
    taskSubitems: list[dict[str, Any]] = Field(default_factory=list)
    taskExecutionRecords: list[dict[str, Any]] = Field(default_factory=list)
    taskSubitemExecutionRecords: list[dict[str, Any]] = Field(default_factory=list)
    dictationSessions: list[dict[str, Any]] = Field(default_factory=list)
    dictationEntries: list[dict[str, Any]] = Field(default_factory=list)
    scheduleItems: list[dict[str, Any]] = Field(default_factory=list)
    calculationRounds: list[dict[str, Any]] = Field(default_factory=list)
    mediaAssets: list[dict[str, Any]] = Field(default_factory=list)
    pointLedgerEntries: list[dict[str, Any]] = Field(default_factory=list)
    pointRewardStates: list[dict[str, Any]] = Field(default_factory=list)


class Mutation(BaseModel):
    mutationID: UUID
    entityType: Literal[
        "reviewItems", "reviewRecords", "taskItems", "taskCompletions",
        "taskSubitems", "taskExecutionRecords", "taskSubitemExecutionRecords",
        "dictationSessions", "dictationEntries", "scheduleItems",
        "calculationRounds",
        "pointLedgerEntries", "pointRewardStates", "settings",
    ]
    recordID: UUID
    operation: Literal["upsert", "delete"]
    updatedAt: datetime
    payload: dict[str, Any] | None = None
    deletionIntent: Literal["explicit"] | None = None


class MutationBatch(BaseModel):
    mutations: list[Mutation] = Field(max_length=1000)
    baseCursor: int | None = Field(default=None, ge=0)
    isolateConflicts: bool = False


class DailyPlanRequest(BaseModel):
    day: date
    dailyLimit: int | None = Field(default=None, ge=0, le=1000)


class ReviewSubmission(BaseModel):
    eventID: UUID
    itemID: UUID
    result: Literal["correct", "wrong"]
    modeRawValue: str = "scheduled"
    reviewedAt: datetime
    note: str = ""


class PairingRequest(BaseModel):
    code: str = Field(min_length=4, max_length=4, pattern=r"^\d{4}$")
    deviceName: str = Field(default="Apple device", max_length=120)


class PairingCodeCreation(BaseModel):
    # Kept for compatibility with the first deployed client/tooling. Pairing
    # codes are now persistent and reusable, so these values are ignored.
    expiresMinutes: int | None = None
    uses: int | None = None


class SecretValueUpdate(BaseModel):
    value: str = Field(min_length=1, max_length=1000)


class DailyQuoteAdminItem(BaseModel):
    id: str = Field(min_length=1, max_length=120)
    text: str = Field(min_length=1, max_length=500)
    kind: Literal["verified", "encouragement"] = "verified"
    attribution: str = Field(default="", max_length=300)
    explanation: str = Field(min_length=1, max_length=1000)
    action: str = Field(min_length=1, max_length=500)
    sortOrder: int = Field(ge=0)


class DailyQuoteAdminImport(BaseModel):
    quotes: list[DailyQuoteAdminItem] = Field(min_length=1, max_length=1000)


@app.get("/health")
async def health() -> dict[str, str]:
    pool = database.require_pool()
    async with pool.acquire() as connection:
        await connection.fetchval("SELECT 1")
    return {"status": "ok", "service": "typo-review-sync"}


@app.get("/v1/content/daily-quote")
async def daily_quote(response: Response) -> dict[str, Any]:
    response.headers["Cache-Control"] = "no-store"
    quote_day = datetime.now(SHANGHAI).date()
    pool = database.require_pool()
    async with pool.acquire() as connection, connection.transaction():
        quote = await fetch_or_assign_daily_quote(connection, quote_day=quote_day)
    if quote is None:
        return {"date": quote_day.isoformat(), "status": "exhausted", "quote": None}
    return {
        "date": quote_day.isoformat(),
        "status": "available",
        "quote": {
            "id": quote["id"],
            "text": quote["quote_text"],
            "kind": quote["kind"],
            "attribution": quote["attribution"],
            "explanation": quote["explanation"],
            "action": quote["action_text"],
        },
    }


@app.get("/v1/admin/daily-quotes/status")
async def daily_quote_admin_status(
    _: UUID = Depends(require_master_token),
) -> dict[str, int | str | None]:
    pool = database.require_pool()
    async with pool.acquire() as connection:
        counts = await connection.fetchrow(
            """
            SELECT
                count(*) FILTER (WHERE q.is_active) AS total,
                count(*) FILTER (WHERE a.quote_id IS NOT NULL) AS used,
                count(*) FILTER (WHERE q.is_active AND a.quote_id IS NULL) AS remaining
            FROM daily_quotes q
            LEFT JOIN daily_quote_assignments a ON a.quote_id=q.id
            """
        )
        last_day = await connection.fetchval(
            "SELECT max(quote_day) FROM daily_quote_assignments"
        )
    return {
        "total": counts["total"],
        "used": counts["used"],
        "remaining": counts["remaining"],
        "lastAssignedDate": last_day.isoformat() if last_day else None,
    }


@app.post("/v1/admin/daily-quotes/import")
async def import_daily_quotes(
    request: DailyQuoteAdminImport,
    _: UUID = Depends(require_master_token),
) -> dict[str, int]:
    ids = [item.id.strip() for item in request.quotes]
    texts = [item.text.strip() for item in request.quotes]
    orders = [item.sortOrder for item in request.quotes]
    if any(
        not item.id.strip()
        or not item.text.strip()
        or not item.explanation.strip()
        or not item.action.strip()
        or (item.kind == "verified" and not item.attribution.strip())
        for item in request.quotes
    ):
        raise HTTPException(status_code=422, detail="quote content is incomplete")
    if (
        len(ids) != len(set(ids))
        or len(texts) != len(set(texts))
        or len(orders) != len(set(orders))
    ):
        raise HTTPException(
            status_code=422,
            detail="quote ids, text values, and sortOrder values must be unique",
        )

    inserted = 0
    updated = 0
    ignored_assigned = 0
    pool = database.require_pool()
    async with pool.acquire() as connection, connection.transaction():
        for item in request.quotes:
            assigned = await connection.fetchval(
                "SELECT EXISTS(SELECT 1 FROM daily_quote_assignments WHERE quote_id=$1)",
                item.id.strip(),
            )
            if assigned:
                ignored_assigned += 1
                continue
            existed = await connection.fetchval(
                "SELECT EXISTS(SELECT 1 FROM daily_quotes WHERE id=$1)",
                item.id.strip(),
            )
            duplicate_text_id = await connection.fetchval(
                """
                SELECT id
                FROM daily_quotes
                WHERE btrim(quote_text)=btrim($1) AND id<>$2
                LIMIT 1
                """,
                item.text.strip(),
                item.id.strip(),
            )
            if duplicate_text_id is not None:
                raise HTTPException(
                    status_code=409,
                    detail=f"quote text already exists as {duplicate_text_id}",
                )
            await connection.execute(
                """
                INSERT INTO daily_quotes(
                    id, quote_text, kind, attribution, explanation, action_text,
                    sort_order, is_active, updated_at
                )
                VALUES($1,$2,$3,$4,$5,$6,$7,true,now())
                ON CONFLICT (id) DO UPDATE
                SET quote_text=EXCLUDED.quote_text,
                    kind=EXCLUDED.kind,
                    attribution=EXCLUDED.attribution,
                    explanation=EXCLUDED.explanation,
                    action_text=EXCLUDED.action_text,
                    sort_order=EXCLUDED.sort_order,
                    is_active=true,
                    updated_at=now()
                """,
                item.id.strip(),
                item.text.strip(),
                item.kind,
                item.attribution.strip(),
                item.explanation.strip(),
                item.action.strip(),
                item.sortOrder,
            )
            if existed:
                updated += 1
            else:
                inserted += 1
    return {
        "inserted": inserted,
        "updated": updated,
        "ignoredAssigned": ignored_assigned,
    }


@app.post("/v1/auth/pairing-code")
async def create_pairing_code(
    request: PairingCodeCreation,
    account_id: UUID = Depends(require_master_token),
) -> dict[str, Any]:
    display_code = f"{secrets.randbelow(10_000):04d}"
    pool = database.require_pool()
    async with pool.acquire() as connection, connection.transaction():
        # A family only needs one active invitation. Removing older codes also
        # prevents a four-digit code from remaining useful after regeneration.
        await connection.execute("DELETE FROM pairing_codes WHERE account_id=$1", account_id)
        await connection.execute("DELETE FROM pairing_attempts")
        await connection.execute(
            """
            INSERT INTO pairing_codes(id, account_id, code_hash, remaining_uses, expires_at, display_code)
            VALUES($1,$2,$3,$4,$5,$6)
            """,
            uuid4(),
            account_id,
            pairing_code_hash(display_code),
            1,
            None,
            display_code,
        )
    return {"code": display_code, "expiresAt": None, "uses": None, "persistent": True}


@app.get("/v1/auth/pairing-code")
async def get_pairing_code(
    account_id: UUID = Depends(require_account),
) -> dict[str, Any]:
    pool = database.require_pool()
    async with pool.acquire() as connection:
        code = await connection.fetchval(
            """
            SELECT display_code
            FROM pairing_codes
            WHERE account_id=$1
              AND display_code IS NOT NULL
              AND (expires_at IS NULL OR expires_at>now())
            ORDER BY created_at DESC
            LIMIT 1
            """,
            account_id,
        )
    if code is None:
        raise HTTPException(status_code=404, detail="pairing code is not available")
    return {"code": code, "persistent": True}


@app.post("/v1/auth/pair")
async def pair_device(request: PairingRequest) -> dict[str, Any]:
    pool = database.require_pool()
    error: HTTPException | None = None
    token = ""
    device_id: UUID | None = None
    account_id: UUID | None = None
    async with pool.acquire() as connection, connection.transaction():
        # The service currently has one family account, so a small global rate
        # limit is both simple and effective against scanning all 10,000 codes.
        await connection.execute("SELECT pg_advisory_xact_lock(9120260723)")
        await connection.execute(
            "DELETE FROM pairing_attempts WHERE attempted_at < now() - interval '24 hours'"
        )
        recent_attempts = await connection.fetchval("SELECT count(*) FROM pairing_attempts")
        if recent_attempts >= 10:
            error = HTTPException(
                status_code=429,
                detail="too many invalid pairing attempts; try again later",
            )
        else:
            row = await connection.fetchrow(
                """
                SELECT id, account_id
                FROM pairing_codes
                WHERE code_hash=$1 AND (expires_at IS NULL OR expires_at>now())
                FOR UPDATE
                """,
                pairing_code_hash(request.code),
            )
            if row is None:
                await connection.execute("INSERT INTO pairing_attempts DEFAULT VALUES")
                error = HTTPException(status_code=401, detail="invalid or expired pairing code")
            else:
                device_id = uuid4()
                account_id = row["account_id"]
                token = secrets.token_urlsafe(48)
                await connection.execute(
                    """
                    INSERT INTO device_tokens(id, account_id, token_hash, device_name)
                    VALUES($1,$2,$3,$4)
                    """,
                    device_id,
                    account_id,
                    hashlib.sha256(token.encode()).hexdigest(),
                    request.deviceName.strip(),
                )
    if error is not None:
        raise error
    if device_id is None or account_id is None:
        raise HTTPException(status_code=500, detail="pairing failed")
    return {"token": token, "accountID": str(account_id), "deviceID": str(device_id)}


@app.delete("/v1/auth/devices/{device_id}")
async def revoke_device(
    device_id: UUID,
    account_id: UUID = Depends(require_master_token),
) -> dict[str, bool]:
    pool = database.require_pool()
    async with pool.acquire() as connection:
        status_value = await connection.execute(
            "UPDATE device_tokens SET revoked_at=now() WHERE id=$1 AND account_id=$2 AND revoked_at IS NULL",
            device_id,
            account_id,
        )
    return {"revoked": status_value.endswith("1")}


def require_secret_encryption_key() -> str:
    key = os.environ.get("SECRET_ENCRYPTION_KEY", "")
    if len(key) < 32:
        raise HTTPException(status_code=503, detail="secret encryption is not configured")
    return key


@app.get("/v1/secrets/deepseek-api-key")
async def get_deepseek_api_key(account_id: UUID = Depends(require_account)) -> dict[str, Any]:
    pool = database.require_pool()
    encryption_key = require_secret_encryption_key()
    async with pool.acquire() as connection:
        row = await connection.fetchrow(
            """
            SELECT pgp_sym_decrypt(ciphertext, $2) AS value, updated_at
            FROM account_secrets
            WHERE account_id=$1 AND secret_name='deepseek-api-key'
            """,
            account_id,
            encryption_key,
        )
    if row is None:
        return {"value": None, "updatedAt": None}
    return {"value": row["value"], "updatedAt": isoformat(row["updated_at"])}


@app.put("/v1/secrets/deepseek-api-key")
async def put_deepseek_api_key(
    request: SecretValueUpdate,
    account_id: UUID = Depends(require_account),
) -> dict[str, Any]:
    value = request.value.strip()
    if not value:
        raise HTTPException(status_code=422, detail="secret value must not be empty")
    pool = database.require_pool()
    encryption_key = require_secret_encryption_key()
    async with pool.acquire() as connection:
        updated_at = await connection.fetchval(
            """
            INSERT INTO account_secrets(account_id, secret_name, ciphertext, updated_at)
            VALUES($1, 'deepseek-api-key', pgp_sym_encrypt($2, $3, 'cipher-algo=aes256'), now())
            ON CONFLICT (account_id, secret_name) DO UPDATE
            SET ciphertext=EXCLUDED.ciphertext, updated_at=EXCLUDED.updated_at
            RETURNING updated_at
            """,
            account_id,
            value,
            encryption_key,
        )
    # Do not echo the secret back in a write response. Authorized devices can
    # retrieve it through the dedicated GET endpoint when synchronizing.
    return {"value": None, "updatedAt": isoformat(updated_at)}


@app.delete("/v1/secrets/deepseek-api-key")
async def delete_deepseek_api_key(account_id: UUID = Depends(require_account)) -> dict[str, bool]:
    pool = database.require_pool()
    async with pool.acquire() as connection:
        status_value = await connection.execute(
            """
            DELETE FROM account_secrets
            WHERE account_id=$1 AND secret_name='deepseek-api-key'
            """,
            account_id,
        )
    return {"deleted": status_value.endswith("1")}


def record_timestamp(entity_type: str, payload: dict[str, Any], fallback: datetime) -> datetime:
    field = UPDATED_AT_FIELD.get(entity_type)
    value = payload.get(field) if field else None
    return parse_datetime(value) or fallback


@app.post("/v1/migration/import")
async def import_snapshot(
    snapshot: SnapshotImport,
    account_id: UUID = Depends(require_account),
) -> dict[str, Any]:
    if snapshot.version > 5:
        raise HTTPException(status_code=422, detail="unsupported backup version")
    pool = database.require_pool()
    inserted_or_updated: dict[str, int] = {}
    exported_at = snapshot.exportedAt.astimezone(timezone.utc)
    async with pool.acquire() as connection, connection.transaction():
        await lock_sync_writes(connection)
        if snapshot.settings is not None:
            settings_payload = canonicalize_settings(snapshot.settings)
            settings_payload.setdefault("updatedAt", isoformat(exported_at))
            changed = await upsert_record(
                connection,
                account_id=account_id,
                entity_type="settings",
                record_id=SETTINGS_RECORD_ID,
                payload=settings_payload,
                client_updated_at=parse_datetime(settings_payload["updatedAt"]) or exported_at,
            )
            inserted_or_updated["settings"] = int(changed)

        raw = snapshot.model_dump(mode="json")
        canonical_points: dict[str, dict[str, Any]] = {}
        for payload in sorted(
            raw["pointLedgerEntries"],
            key=lambda value: (value.get("createdAt", ""), value.get("id", "")),
        ):
            key = payload.get("idempotencyKey") or f"legacy-{payload['id']}"
            canonical_points.setdefault(key, payload)
        ignored_point_duplicates = len(raw["pointLedgerEntries"]) - len(canonical_points)
        raw["pointLedgerEntries"] = list(canonical_points.values())
        for entity_type in ENTITY_KEYS:
            changed_count = 0
            for payload in raw[entity_type]:
                if entity_type == "pointLedgerEntries":
                    changed, duplicate = await upsert_point_ledger_entry(
                        connection,
                        account_id=account_id,
                        record_id=UUID(str(payload["id"])),
                        payload=payload,
                        client_updated_at=record_timestamp(entity_type, payload, exported_at),
                    )
                    ignored_point_duplicates += int(duplicate)
                else:
                    changed = await upsert_record(
                        connection,
                        account_id=account_id,
                        entity_type=entity_type,
                        record_id=UUID(str(payload["id"])),
                        payload=payload,
                        client_updated_at=record_timestamp(entity_type, payload, exported_at),
                    )
                changed_count += int(changed)
            inserted_or_updated[entity_type] = changed_count

    return {
        "ok": True,
        "changed": inserted_or_updated,
        "ignoredMediaAssets": len(snapshot.mediaAssets),
        "ignoredDuplicatePointEntries": ignored_point_duplicates,
    }


@app.get("/v1/migration/export")
async def export_snapshot(account_id: UUID = Depends(require_account)) -> dict[str, Any]:
    pool = database.require_pool()
    async with pool.acquire() as connection, connection.transaction(isolation="repeatable_read", readonly=True):
        settings = await connection.fetchval(
            """
            SELECT payload
            FROM records
            WHERE account_id = $1
              AND entity_type = 'settings'
              AND deleted_at IS NULL
            ORDER BY client_updated_at DESC, server_version DESC
            LIMIT 1
            """,
            account_id,
        )
        rows = await connection.fetch(
            """
            SELECT entity_type, payload
            FROM records
            WHERE account_id = $1
              AND entity_type <> 'settings'
              AND deleted_at IS NULL
            ORDER BY entity_type, record_id
            """,
            account_id,
        )
    result: dict[str, Any] = {
        "version": 5,
        "exportedAt": isoformat(datetime.now(timezone.utc)),
        "appVersion": "server-1.0",
        "settings": canonicalize_settings(settings) if settings is not None else None,
        **{key: [] for key in ENTITY_KEYS},
        "mediaAssets": [],
    }
    for row in rows:
        payload = json.loads(row["payload"]) if isinstance(row["payload"], str) else row["payload"]
        if row["entity_type"] in ENTITY_KEYS:
            result[row["entity_type"]].append(payload)
    return result


@app.get("/v1/sync/manifest")
async def sync_manifest(account_id: UUID = Depends(require_account)) -> dict[str, Any]:
    """Small version inventory for verifying a device without sending payloads."""
    async with database.require_pool().acquire() as connection:
        rows = await connection.fetch(
            "SELECT entity_type, record_id, server_version, deleted_at FROM records WHERE account_id=$1 ORDER BY server_version",
            account_id,
        )
    return {
        "protocolVersion": 2,
        "cursor": max((r["server_version"] for r in rows), default=0),
        "records": [{"entityType": r["entity_type"], "recordID": str(r["record_id"]),
                     "serverVersion": r["server_version"], "deleted": r["deleted_at"] is not None} for r in rows],
    }


@app.get("/v1/sync/changes")
async def changes(
    after: int = Query(default=0, ge=0),
    limit: int = Query(default=1000, ge=1, le=5000),
    account_id: UUID = Depends(require_account),
) -> dict[str, Any]:
    pool = database.require_pool()
    async with pool.acquire() as connection:
        rows = await connection.fetch(
            """
            SELECT entity_type, record_id, payload, client_updated_at,
                   server_version, deleted_at
            FROM records
            WHERE account_id = $1 AND server_version > $2
            ORDER BY server_version
            LIMIT $3
            """,
            account_id,
            after,
            limit,
        )
    values = []
    for row in rows:
        values.append({
            "entityType": row["entity_type"],
            "recordID": str(row["record_id"]),
            "payload": row["payload"],
            "updatedAt": isoformat(row["client_updated_at"]),
            "serverVersion": row["server_version"],
            "deletedAt": isoformat(row["deleted_at"]) if row["deleted_at"] else None,
        })
    return {"changes": values, "cursor": values[-1]["serverVersion"] if values else after}


@app.post("/v1/sync/push")
async def push_mutations(
    batch: MutationBatch,
    account_id: UUID = Depends(require_account),
) -> dict[str, Any]:
    pool = database.require_pool()
    applied: list[str] = []
    conflicts: list[dict[str, Any]] = []
    server_scheduled_item_ids: set[UUID] = set()
    rejected_review_item_ids: set[UUID] = set()
    async with pool.acquire() as connection, connection.transaction():
        await lock_sync_writes(connection)
        if batch.baseCursor is not None:
            for mutation in batch.mutations:
                if mutation.operation == "delete" and mutation.deletionIntent == "explicit":
                    continue
                if await connection.fetchval(
                    "SELECT 1 FROM processed_mutations WHERE account_id=$1 AND mutation_id=$2", account_id, mutation.mutationID
                ):
                    continue
                if mutation.operation == "upsert" and await connection.fetchval(
                    "SELECT deleted_at FROM records WHERE account_id=$1 AND entity_type=$2 AND record_id=$3",
                    account_id, mutation.entityType, mutation.recordID,
                ) is not None:
                    continue
                if await record_has_changed_after(
                    connection,
                    account_id=account_id,
                    entity_type=mutation.entityType,
                    record_id=mutation.recordID,
                    base_cursor=batch.baseCursor,
                    proposed_payload=mutation.payload,
                    is_delete=mutation.operation == "delete",
                ):
                    raise HTTPException(
                        status_code=409,
                        detail={
                            "reason": "sync_record_changed",
                            "entityType": mutation.entityType,
                            "recordID": str(mutation.recordID),
                        },
                    )
        for mutation in batch.mutations:
            try:
                async with connection.transaction():
                    claimed = await connection.fetchval(
                        """
                        INSERT INTO processed_mutations(account_id, mutation_id)
                        VALUES($1, $2)
                        ON CONFLICT DO NOTHING
                        RETURNING mutation_id
                        """,
                        account_id,
                        mutation.mutationID,
                    )
                    if claimed is None:
                        applied.append(str(mutation.mutationID))
                        continue
                    if mutation.operation == "upsert" and await connection.fetchval(
                        "SELECT deleted_at FROM records WHERE account_id=$1 AND entity_type=$2 AND record_id=$3",
                        account_id, mutation.entityType, mutation.recordID,
                    ) is not None:
                        applied.append(str(mutation.mutationID))
                        continue
                    if mutation.operation == "delete" and not should_apply_sync_delete(mutation.deletionIntent):
                        # Legacy clients inferred deletes whenever a record was absent
                        # from their local snapshot. A partial store must never erase the
                        # authoritative family data. Acknowledge the mutation so the
                        # client can continue with its pull, but keep the record intact.
                        applied.append(str(mutation.mutationID))
                        continue
                    if mutation.entityType == "settings" and mutation.operation == "delete":
                        # Settings are a per-account singleton. A device that previously
                        # used a different local UUID must not delete the family's settings.
                        applied.append(str(mutation.mutationID))
                        continue
                    if mutation.operation == "delete":
                        await tombstone_record(
                            connection,
                            account_id=account_id,
                            entity_type=mutation.entityType,
                            record_id=mutation.recordID,
                            deleted_at=mutation.updatedAt,
                        )
                        if mutation.entityType == "reviewRecords":
                            await connection.execute(
                                """UPDATE daily_review_plan_items i
                                   SET completed_event_id=NULL, completed_at=NULL
                                   FROM daily_review_plans p
                                   WHERE i.plan_id=p.id AND p.account_id=$1 AND i.completed_event_id=$2""",
                                account_id, mutation.recordID,
                            )
                    else:
                        if mutation.payload is None:
                            raise HTTPException(status_code=422, detail="upsert payload is required")
                        if mutation.entityType == "settings":
                            settings_updated_at = parse_datetime(mutation.payload.get("updatedAt"))
                            if settings_updated_at is None:
                                # Builds released before settings gained an edit timestamp
                                # may contain stale defaults. They can download settings,
                                # but must not overwrite a newer family value.
                                applied.append(str(mutation.mutationID))
                                continue
                            await upsert_record(
                                connection,
                                account_id=account_id,
                                entity_type="settings",
                                record_id=SETTINGS_RECORD_ID,
                                payload=canonicalize_settings(mutation.payload),
                                client_updated_at=settings_updated_at,
                            )
                            applied.append(str(mutation.mutationID))
                            continue
                        if mutation.entityType == "reviewRecords" and mutation.payload.get("modeRawValue") != "dictation":
                            reviewed_at = parse_datetime(mutation.payload.get("reviewedAt"))
                            item_id_value = mutation.payload.get("itemID")
                            result = mutation.payload.get("resultRawValue")
                            if reviewed_at is None or item_id_value is None or result not in {"correct", "wrong"}:
                                raise HTTPException(status_code=422, detail="invalid scheduled review mutation")
                            item_id = UUID(str(item_id_value))
                            prior = await connection.fetchval(
                                "SELECT payload FROM records WHERE account_id=$1 AND entity_type='reviewRecords' AND record_id=$2 AND deleted_at IS NULL",
                                account_id,
                                mutation.recordID,
                            )
                            if prior is None:
                                same_day_record = await connection.fetchrow(
                                    """
                                    SELECT record_id, payload FROM records
                                    WHERE account_id=$1
                                      AND entity_type='reviewRecords'
                                      AND deleted_at IS NULL
                                      AND upper(payload->>'itemID')=upper($2)
                                      AND COALESCE(payload->>'modeRawValue', '') <> 'dictation'
                                      AND ((payload->>'reviewedAt')::timestamptz AT TIME ZONE 'Asia/Shanghai')::date=$3
                                    LIMIT 1
                                    """,
                                    account_id,
                                    str(item_id),
                                    reviewed_at.astimezone(SHANGHAI).date(),
                                )
                                if same_day_record is not None:
                                    if same_day_record["payload"].get("resultRawValue") == result:
                                        # Two devices completed the same daily review. Keep
                                        # one canonical event and explicitly retire the copy.
                                        await tombstone_record(connection, account_id=account_id,
                                                               entity_type="reviewRecords", record_id=mutation.recordID,
                                                               deleted_at=mutation.updatedAt)
                                        server_scheduled_item_ids.add(item_id)
                                        applied.append(str(mutation.mutationID))
                                        continue
                                    raise HTTPException(
                                        status_code=409,
                                        detail={"reason": "item_already_reviewed_today", "itemID": str(item_id)},
                                    )
                                row = await connection.fetchrow(
                                    """
                                    SELECT payload FROM records
                                    WHERE account_id=$1 AND entity_type='reviewItems' AND record_id=$2 AND deleted_at IS NULL
                                    FOR UPDATE
                                    """,
                                    account_id,
                                    item_id,
                                )
                                if row is None:
                                    raise HTTPException(status_code=404, detail="review item not found")
                                item = row["payload"]
                                if not is_due(item, reviewed_at.astimezone(SHANGHAI).date()):
                                    raise HTTPException(
                                        status_code=409,
                                        detail={"reason": "item_already_reviewed", "itemID": str(item_id)},
                                    )
                                updated_item, old_stage, new_stage = apply_review_result(
                                    item,
                                    result=result,
                                    reviewed_at=reviewed_at,
                                )
                                canonical_record = {
                                    **mutation.payload,
                                    "id": str(mutation.recordID),
                                    "itemID": str(item_id),
                                    "reviewedAt": isoformat(reviewed_at),
                                    "oldStage": old_stage,
                                    "newStage": new_stage,
                                }
                                await upsert_record(
                                    connection,
                                    account_id=account_id,
                                    entity_type="reviewItems",
                                    record_id=item_id,
                                    payload=updated_item,
                                    client_updated_at=max(reviewed_at, mutation.updatedAt),
                                )
                                await upsert_record(
                                    connection,
                                    account_id=account_id,
                                    entity_type="reviewRecords",
                                    record_id=mutation.recordID,
                                    payload=canonical_record,
                                    client_updated_at=max(reviewed_at, mutation.updatedAt),
                                )
                                await connection.execute(
                                    """
                                    UPDATE daily_review_plan_items i
                                    SET completed_event_id=$3, completed_at=$4
                                    FROM daily_review_plans p
                                    WHERE i.plan_id=p.id AND p.account_id=$1 AND p.plan_day=$2 AND i.item_id=$5
                                    """,
                                    account_id,
                                    reviewed_at.astimezone(SHANGHAI).date(),
                                    mutation.recordID,
                                    reviewed_at,
                                    item_id,
                                )
                            server_scheduled_item_ids.add(item_id)
                            applied.append(str(mutation.mutationID))
                            continue
                        if mutation.entityType == "reviewItems" and mutation.recordID in rejected_review_item_ids:
                            raise HTTPException(status_code=409, detail={"reason": "dependent_review_conflict", "itemID": str(mutation.recordID)})
                        if mutation.entityType == "reviewItems" and mutation.recordID in server_scheduled_item_ids:
                            applied.append(str(mutation.mutationID))
                            continue
                        if mutation.entityType == "pointLedgerEntries":
                            await upsert_point_ledger_entry(
                                connection,
                                account_id=account_id,
                                record_id=mutation.recordID,
                                payload=mutation.payload,
                                client_updated_at=mutation.updatedAt,
                            )
                        else:
                            await upsert_record(
                                connection,
                                account_id=account_id,
                                entity_type=mutation.entityType,
                                record_id=mutation.recordID,
                                payload=mutation.payload,
                                client_updated_at=mutation.updatedAt,
                            )
                    applied.append(str(mutation.mutationID))
            except HTTPException as error:
                if not batch.isolateConflicts or error.status_code not in {404, 409, 422}:
                    raise
                if mutation.entityType == "reviewRecords" and mutation.payload:
                    item_id = mutation.payload.get("itemID")
                    if item_id:
                        rejected_review_item_ids.add(UUID(str(item_id)))
                conflicts.append({"mutationID": str(mutation.mutationID), "entityType": mutation.entityType,
                                  "recordID": str(mutation.recordID), "statusCode": error.status_code,
                                  "reason": error.detail})
    return {"appliedMutationIDs": applied, "conflicts": conflicts}


async def load_plan(connection: asyncpg.Connection, account_id: UUID, plan_day: date) -> dict[str, Any] | None:
    plan = await connection.fetchrow(
        "SELECT id, plan_day, daily_limit, created_at, updated_at FROM daily_review_plans WHERE account_id=$1 AND plan_day=$2",
        account_id,
        plan_day,
    )
    if plan is None:
        return None
    items = await connection.fetch(
        """
        SELECT item_id, position, completed_event_id, completed_at
        FROM daily_review_plan_items
        WHERE plan_id=$1 ORDER BY position
        """,
        plan["id"],
    )
    return {
        "id": str(plan["id"]),
        "day": plan["plan_day"].isoformat(),
        "dailyLimit": plan["daily_limit"],
        "createdAt": isoformat(plan["created_at"]),
        "updatedAt": isoformat(plan["updated_at"]),
        "items": [
            {
                "itemID": str(item["item_id"]),
                "position": item["position"],
                "completedEventID": str(item["completed_event_id"]) if item["completed_event_id"] else None,
                "completedAt": isoformat(item["completed_at"]) if item["completed_at"] else None,
            }
            for item in items
        ],
    }


@app.post("/v1/review/daily-plan")
async def daily_plan(
    request: DailyPlanRequest,
    account_id: UUID = Depends(require_account),
) -> dict[str, Any]:
    pool = database.require_pool()
    async with pool.acquire() as connection, connection.transaction():
        await connection.execute("SELECT pg_advisory_xact_lock(hashtext($1))", f"{account_id}:{request.day}")
        existing = await load_plan(connection, account_id, request.day)
        if existing is not None:
            return existing

        daily_limit = request.dailyLimit
        if daily_limit is None:
            settings = await connection.fetchval(
                "SELECT payload FROM records WHERE account_id=$1 AND entity_type='settings' AND deleted_at IS NULL ORDER BY client_updated_at DESC LIMIT 1",
                account_id,
            )
            daily_limit = int((settings or {}).get("dailyLimit", 50))
        daily_limit = max(0, min(daily_limit, 1000))

        review_rows = await connection.fetch(
            "SELECT payload FROM records WHERE account_id=$1 AND entity_type='reviewRecords' AND deleted_at IS NULL",
            account_id,
        )
        reviewed_pairs: list[tuple[datetime, UUID]] = []
        for row in review_rows:
            payload = row["payload"]
            reviewed_at = parse_datetime(payload.get("reviewedAt"))
            if reviewed_at is None or reviewed_at.astimezone(SHANGHAI).date() != request.day:
                continue
            if payload.get("modeRawValue") == "dictation":
                continue
            reviewed_pairs.append((reviewed_at, UUID(str(payload["itemID"]))))
        reviewed_pairs.sort(key=lambda pair: (pair[0], str(pair[1])))
        reviewed_ids = unique_ids(item_id for _, item_id in reviewed_pairs)

        item_rows = await connection.fetch(
            "SELECT record_id, payload FROM records WHERE account_id=$1 AND entity_type='reviewItems' AND deleted_at IS NULL",
            account_id,
        )
        due = []
        reviewed_set = set(reviewed_ids)
        for row in item_rows:
            item_id = row["record_id"]
            payload = row["payload"]
            if item_id in reviewed_set or not is_due(payload, request.day):
                continue
            due.append((parse_datetime(payload.get("nextReviewAt")), parse_datetime(payload.get("createdAt")), str(item_id), item_id))
        due.sort(key=lambda value: (value[0], value[1], value[2]))
        selected = unique_ids([*reviewed_ids, *(value[3] for value in due)])[:daily_limit]

        plan_id = uuid4()
        await connection.execute(
            "INSERT INTO daily_review_plans(id, account_id, plan_day, daily_limit) VALUES($1,$2,$3,$4)",
            plan_id,
            account_id,
            request.day,
            daily_limit,
        )
        for position, item_id in enumerate(selected):
            completed_at = next((when for when, candidate in reviewed_pairs if candidate == item_id), None)
            await connection.execute(
                "INSERT INTO daily_review_plan_items(plan_id,item_id,position,completed_at) VALUES($1,$2,$3,$4)",
                plan_id,
                item_id,
                position,
                completed_at,
            )
        return (await load_plan(connection, account_id, request.day)) or {}


@app.post("/v1/review/submit")
async def submit_review(
    submission: ReviewSubmission,
    account_id: UUID = Depends(require_account),
) -> dict[str, Any]:
    reviewed_at = submission.reviewedAt.astimezone(timezone.utc)
    pool = database.require_pool()
    async with pool.acquire() as connection, connection.transaction():
        await lock_sync_writes(connection)
        prior = await connection.fetchval(
            "SELECT payload FROM records WHERE account_id=$1 AND entity_type='reviewRecords' AND record_id=$2 AND deleted_at IS NULL",
            account_id,
            submission.eventID,
        )
        if prior is not None:
            return {"accepted": True, "idempotent": True, "record": prior}

        same_day_record = await connection.fetchval(
            """
            SELECT record_id FROM records
            WHERE account_id=$1
              AND entity_type='reviewRecords'
              AND deleted_at IS NULL
              AND upper(payload->>'itemID')=upper($2)
              AND COALESCE(payload->>'modeRawValue', '') <> 'dictation'
              AND ((payload->>'reviewedAt')::timestamptz AT TIME ZONE 'Asia/Shanghai')::date=$3
            LIMIT 1
            """,
            account_id,
            str(submission.itemID),
            reviewed_at.astimezone(SHANGHAI).date(),
        )
        if same_day_record is not None:
            raise HTTPException(
                status_code=409,
                detail={"reason": "item_already_reviewed_today", "itemID": str(submission.itemID)},
            )

        row = await connection.fetchrow(
            """
            SELECT payload FROM records
            WHERE account_id=$1 AND entity_type='reviewItems' AND record_id=$2 AND deleted_at IS NULL
            FOR UPDATE
            """,
            account_id,
            submission.itemID,
        )
        if row is None:
            raise HTTPException(status_code=404, detail="review item not found")
        item = row["payload"]
        if not is_due(item, reviewed_at.astimezone(SHANGHAI).date()):
            raise HTTPException(status_code=409, detail={"reason": "item_not_due", "item": item})

        updated_item, old_stage, new_stage = apply_review_result(
            item,
            result=submission.result,
            reviewed_at=reviewed_at,
        )
        record = {
            "id": str(submission.eventID),
            "itemID": str(submission.itemID),
            "reviewedAt": isoformat(reviewed_at),
            "resultRawValue": submission.result,
            "modeRawValue": submission.modeRawValue,
            "oldStage": old_stage,
            "newStage": new_stage,
            "note": submission.note,
        }
        await upsert_record(
            connection,
            account_id=account_id,
            entity_type="reviewItems",
            record_id=submission.itemID,
            payload=updated_item,
            client_updated_at=reviewed_at,
        )
        await upsert_record(
            connection,
            account_id=account_id,
            entity_type="reviewRecords",
            record_id=submission.eventID,
            payload=record,
            client_updated_at=reviewed_at,
        )
        await connection.execute(
            """
            UPDATE daily_review_plan_items i
            SET completed_event_id=$3, completed_at=$4
            FROM daily_review_plans p
            WHERE i.plan_id=p.id AND p.account_id=$1 AND p.plan_day=$2 AND i.item_id=$5
            """,
            account_id,
            reviewed_at.astimezone(SHANGHAI).date(),
            submission.eventID,
            reviewed_at,
            submission.itemID,
        )
        return {"accepted": True, "idempotent": False, "item": updated_item, "record": record}
