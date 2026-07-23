#!/bin/sh
set -eu

mkdir -p /backups

while true; do
    stamp="$(date -u +%Y%m%d-%H%M%S)"
    temporary="/backups/typo-review-${stamp}.dump.tmp"
    completed="/backups/typo-review-${stamp}.dump"
    pg_dump --format=custom --no-owner --no-privileges --file="$temporary" "$DATABASE_URL"
    mv "$temporary" "$completed"
    find /backups -type f -name 'typo-review-*.dump' -mtime +14 -delete
    sleep 86400
done
