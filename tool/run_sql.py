"""Runs the repo's SQL files against the Supabase pooler — psql isn't
installed here, and psycopg's ClientCursor uses the simple query protocol so
multi-statement scripts behave like SQL Editor / `psql -f`.

Emulates just enough psql for the test suite: \\echo prints, \\gset captures a
single-row result into variables, and :'var' / :var interpolate them.
"""
import os
import re
import sys
import psycopg
from psycopg import ClientCursor

# Same env var the rest of the repo uses; never hardcode the database
# password here — this file is committed.
DSN = os.environ.get("SUPABASE_DB_URL")

_VAR_QUOTED = re.compile(r":'(\w+)'")
_VAR_BARE = re.compile(r"(?<!:):(\w+)")


def _substitute(sql: str, vars_: dict[str, object]) -> str:
    def quoted(m: re.Match) -> str:
        return "'" + str(vars_[m.group(1)]).replace("'", "''") + "'"

    sql = _VAR_QUOTED.sub(quoted, sql)
    return _VAR_BARE.sub(lambda m: str(vars_[m.group(1)]), sql)


def run(path: str) -> None:
    """Split at psql meta-command lines; run each SQL chunk, capture gset."""
    vars_: dict[str, object] = {}
    pending: list[str] = []
    pending_is_gset = False

    def flush(conn) -> None:
        nonlocal pending_is_gset
        sql = _substitute("\n".join(pending), vars_)
        pending.clear()
        if not sql.strip():
            return
        with conn.cursor() as cur:
            cur.execute(sql)
            if pending_is_gset:
                # A multi-statement batch: walk to the final result set —
                # that's the SELECT the \gset was attached to.
                while cur.nextset():
                    pass
                if cur.description:
                    row = cur.fetchone()
                    if row:
                        vars_.update(
                            {d.name: v for d, v in zip(cur.description, row)}
                        )
        pending_is_gset = False

    with open(path, encoding="utf-8") as fh:
        lines = fh.readlines()

    with psycopg.connect(
        DSN, autocommit=True, cursor_factory=ClientCursor
    ) as conn:
        conn.add_notice_handler(
            lambda n: print(f"  NOTICE: {n.message_primary}", flush=True)
        )
        for line in lines:
            stripped = line.strip()
            if stripped.startswith("\\echo"):
                flush(conn)
                print(" ", stripped[5:].strip().strip("'"), flush=True)
            elif stripped.startswith("\\gset"):
                pending_is_gset = True
                flush(conn)
            elif stripped.startswith("\\"):
                flush(conn)
                print(f"  (skipped meta-command: {stripped})", flush=True)
            else:
                pending.append(line)
        flush(conn)
    print(f"OK  {path}", flush=True)


if __name__ == "__main__":
    if not DSN:
        sys.exit("SUPABASE_DB_URL is not set")
    for f in sys.argv[1:]:
        print(f"--- {f}", flush=True)
        try:
            run(f)
        except psycopg.Error as e:
            print(f"FAIL {f}: {e}", flush=True)
            sys.exit(1)
