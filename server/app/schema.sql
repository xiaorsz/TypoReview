CREATE SEQUENCE IF NOT EXISTS record_version_seq;

CREATE TABLE IF NOT EXISTS accounts (
    id uuid PRIMARY KEY,
    display_name text NOT NULL DEFAULT '家庭账户',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS records (
    account_id uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    entity_type text NOT NULL,
    record_id uuid NOT NULL,
    payload jsonb NOT NULL,
    client_updated_at timestamptz NOT NULL,
    server_version bigint NOT NULL DEFAULT nextval('record_version_seq'),
    deleted_at timestamptz,
    PRIMARY KEY (account_id, entity_type, record_id)
);

CREATE INDEX IF NOT EXISTS records_changes_idx
    ON records(account_id, server_version);
CREATE INDEX IF NOT EXISTS records_entity_idx
    ON records(account_id, entity_type) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS point_ledger_idempotency_idx
    ON records(account_id, (payload->>'idempotencyKey'))
    WHERE entity_type = 'pointLedgerEntries'
      AND deleted_at IS NULL
      AND COALESCE(payload->>'idempotencyKey', '') <> '';

CREATE OR REPLACE FUNCTION bump_record_version() RETURNS trigger AS $$
BEGIN
    NEW.server_version := nextval('record_version_seq');
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS records_bump_version ON records;
CREATE TRIGGER records_bump_version
BEFORE UPDATE ON records
FOR EACH ROW EXECUTE FUNCTION bump_record_version();

CREATE TABLE IF NOT EXISTS processed_mutations (
    account_id uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    mutation_id uuid NOT NULL,
    processed_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, mutation_id)
);

CREATE TABLE IF NOT EXISTS device_tokens (
    id uuid PRIMARY KEY,
    account_id uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    token_hash text NOT NULL UNIQUE,
    device_name text NOT NULL DEFAULT '',
    created_at timestamptz NOT NULL DEFAULT now(),
    last_used_at timestamptz,
    revoked_at timestamptz
);

CREATE TABLE IF NOT EXISTS pairing_codes (
    id uuid PRIMARY KEY,
    account_id uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    code_hash text NOT NULL UNIQUE,
    remaining_uses integer NOT NULL DEFAULT 1 CHECK (remaining_uses >= 0),
    expires_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE pairing_codes ALTER COLUMN expires_at DROP NOT NULL;
ALTER TABLE pairing_codes ADD COLUMN IF NOT EXISTS display_code text;

CREATE TABLE IF NOT EXISTS pairing_attempts (
    id bigserial PRIMARY KEY,
    attempted_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS pairing_attempts_time_idx
    ON pairing_attempts(attempted_at);

CREATE TABLE IF NOT EXISTS daily_review_plans (
    id uuid PRIMARY KEY,
    account_id uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    plan_day date NOT NULL,
    daily_limit integer NOT NULL CHECK (daily_limit >= 0 AND daily_limit <= 1000),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (account_id, plan_day)
);

CREATE TABLE IF NOT EXISTS daily_review_plan_items (
    plan_id uuid NOT NULL REFERENCES daily_review_plans(id) ON DELETE CASCADE,
    item_id uuid NOT NULL,
    position integer NOT NULL CHECK (position >= 0),
    completed_event_id uuid,
    completed_at timestamptz,
    PRIMARY KEY (plan_id, item_id),
    UNIQUE (plan_id, position)
);

CREATE INDEX IF NOT EXISTS daily_review_plan_items_item_idx
    ON daily_review_plan_items(item_id);
