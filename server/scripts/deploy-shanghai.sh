#!/usr/bin/env bash
set -Eeuo pipefail

readonly DEPLOY_HOST="${TYPO_REVIEW_DEPLOY_HOST:-ubuntu@111.231.22.148}"
readonly DEPLOY_KEY="${TYPO_REVIEW_SSH_KEY:-/Users/xiaorsz/.ssh/luye-shanghai.pem}"
readonly REMOTE_ROOT="${TYPO_REVIEW_REMOTE_ROOT:-/opt/typo-review-sync}"
readonly PROJECT_NAME="typo-review-sync"
readonly STAMP="$(date +%Y%m%d-%H%M%S)"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SERVER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly ARCHIVE="/tmp/typo-review-sync-${STAMP}.tar.gz"
readonly REMOTE_ARCHIVE="/tmp/typo-review-sync-${STAMP}.tar.gz"
readonly SSH_OPTIONS=(-i "$DEPLOY_KEY" -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new)

cleanup() {
  rm -f "$ARCHIVE"
  ssh "${SSH_OPTIONS[@]}" "$DEPLOY_HOST" "rm -f '$REMOTE_ARCHIVE'" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if [[ ! -f "$DEPLOY_KEY" ]]; then
  echo "SSH key not found: $DEPLOY_KEY" >&2
  exit 1
fi

tar -C "$SERVER_DIR" \
  --exclude='.env.production' \
  --exclude='__pycache__' \
  --exclude='*.pyc' \
  --exclude='tests' \
  -czf "$ARCHIVE" .

scp "${SSH_OPTIONS[@]}" "$ARCHIVE" "$DEPLOY_HOST:$REMOTE_ARCHIVE"

ssh "${SSH_OPTIONS[@]}" "$DEPLOY_HOST" "bash -s -- '$REMOTE_ROOT' '$REMOTE_ARCHIVE' '$STAMP' '$PROJECT_NAME'" <<'REMOTE'
set -Eeuo pipefail
remote_root="$1"
archive="$2"
stamp="$3"
project_name="$4"
release_dir="$remote_root/releases/$stamp"
current_link="$remote_root/current"
env_file="$remote_root/.env.production"

before_existing="$(sudo docker ps --filter 'name=luye-content-workbench' --format '{{.ID}}|{{.Names}}' | sort)"

sudo mkdir -p "$release_dir"
sudo mkdir -p "$remote_root/backups"
sudo tar -xzf "$archive" -C "$release_dir"
sudo chown -R ubuntu:ubuntu "$remote_root"

if [[ ! -f "$env_file" ]]; then
  umask 077
  db_password="$(openssl rand -hex 32)"
  api_token="$(openssl rand -hex 32)"
  {
    printf 'POSTGRES_DB=typo_review\n'
    printf 'POSTGRES_USER=typo_review\n'
    printf 'POSTGRES_PASSWORD=%s\n' "$db_password"
    printf 'DATABASE_URL=postgresql://typo_review:%s@postgres:5432/typo_review\n' "$db_password"
    printf 'API_TOKEN=%s\n' "$api_token"
    printf 'DEFAULT_ACCOUNT_ID=00000000-0000-0000-0000-000000000001\n'
    printf 'SECRET_ENCRYPTION_KEY=%s\n' "$(openssl rand -hex 32)"
  } > "$env_file"
fi
if ! grep -q '^SECRET_ENCRYPTION_KEY=' "$env_file"; then
  printf 'SECRET_ENCRYPTION_KEY=%s\n' "$(openssl rand -hex 32)" >> "$env_file"
fi
chmod 600 "$env_file"
ln -sfn "$release_dir" "$current_link"

cd "$current_link"
sudo docker compose --project-name "$project_name" --env-file "$env_file" -f compose.production.yml up -d --build

for _ in $(seq 1 30); do
  if curl --fail --silent http://127.0.0.1:18181/health >/dev/null; then
    break
  fi
  sleep 2
done
curl --fail --silent http://127.0.0.1:18181/health

after_existing="$(sudo docker ps --filter 'name=luye-content-workbench' --format '{{.ID}}|{{.Names}}' | sort)"
if [[ "$before_existing" != "$after_existing" ]]; then
  echo 'Existing luye-content-workbench container identities changed unexpectedly.' >&2
  exit 1
fi

sudo docker compose --project-name "$project_name" --env-file "$env_file" -f compose.production.yml ps
printf '\nDEPLOYED_RELEASE=%s\n' "$release_dir"
REMOTE
