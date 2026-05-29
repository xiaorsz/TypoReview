#!/usr/bin/env python3
import argparse
import csv
import os
import re
import sqlite3


WORD_PATTERN = re.compile(r"^[a-z][a-z '\-]*$")
FREQUENCY_LIMIT = 30000
KEPT_TAGS = {"zk", "gk"}


def as_int(value):
    try:
        return int(value or 0)
    except ValueError:
        return 0


def should_keep(row):
    word = (row.get("word") or "").strip().lower()
    translation = (row.get("translation") or "").strip()
    if not word or not translation:
        return False
    if not WORD_PATTERN.match(word):
        return False

    tags = set((row.get("tag") or "").split())
    bnc = as_int(row.get("bnc"))
    frq = as_int(row.get("frq"))
    oxford = as_int(row.get("oxford"))

    return bool(
        KEPT_TAGS.intersection(tags)
        or oxford > 0
        or 0 < bnc <= FREQUENCY_LIMIT
        or 0 < frq <= FREQUENCY_LIMIT
    )


def build_database(input_csv, output_sqlite):
    os.makedirs(os.path.dirname(output_sqlite), exist_ok=True)
    if os.path.exists(output_sqlite):
        os.remove(output_sqlite)

    connection = sqlite3.connect(output_sqlite)
    try:
        connection.execute("PRAGMA journal_mode = OFF")
        connection.execute("PRAGMA synchronous = OFF")
        connection.execute(
            """
            CREATE TABLE entries (
                word TEXT PRIMARY KEY,
                phonetic TEXT NOT NULL DEFAULT '',
                translation TEXT NOT NULL DEFAULT '',
                pos TEXT NOT NULL DEFAULT '',
                tag TEXT NOT NULL DEFAULT '',
                bnc INTEGER NOT NULL DEFAULT 0,
                frq INTEGER NOT NULL DEFAULT 0,
                exchange TEXT NOT NULL DEFAULT ''
            )
            """
        )

        inserted = 0
        with open(input_csv, newline="", encoding="utf-8") as handle:
            reader = csv.DictReader(handle)
            for row in reader:
                if not should_keep(row):
                    continue

                word = (row.get("word") or "").strip().lower()
                connection.execute(
                    """
                    INSERT OR REPLACE INTO entries
                    (word, phonetic, translation, pos, tag, bnc, frq, exchange)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        word,
                        (row.get("phonetic") or "").strip(),
                        (row.get("translation") or "").strip(),
                        (row.get("pos") or "").strip(),
                        (row.get("tag") or "").strip(),
                        as_int(row.get("bnc")),
                        as_int(row.get("frq")),
                        (row.get("exchange") or "").strip(),
                    ),
                )
                inserted += 1

        connection.execute("CREATE INDEX entries_tag_idx ON entries(tag)")
        connection.execute("CREATE INDEX entries_bnc_idx ON entries(bnc)")
        connection.execute("CREATE INDEX entries_frq_idx ON entries(frq)")
        connection.commit()
        connection.execute("VACUUM")
        connection.commit()
        return inserted
    finally:
        connection.close()


def main():
    parser = argparse.ArgumentParser(
        description="Build the app's compact ECDICT SQLite resource."
    )
    parser.add_argument("input_csv", help="Path to ECDICT ecdict.csv")
    parser.add_argument("output_sqlite", help="Output SQLite path")
    args = parser.parse_args()

    count = build_database(args.input_csv, args.output_sqlite)
    print(f"wrote {count} entries to {args.output_sqlite}")


if __name__ == "__main__":
    main()
