"""State storage. `Repo` is the interface; `MariaRepo` is the production implementation (InnoDB),
`MemoryRepo` is a fake with the same semantics for tests. All times are naive UTC datetimes."""

from __future__ import annotations

import hashlib
import queue
import threading
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path

from . import config

MIGRATIONS_DIR = Path(__file__).resolve().parent.parent / "migrations"


@dataclass(frozen=True)
class SlotRef:
    run_id: str
    slot_id: str
    slot_index: int
    slot_time: datetime


@dataclass(frozen=True)
class SlotBlob:
    content_type: str
    sha256: str
    data: bytes


def _now() -> datetime:
    return datetime.now(UTC).replace(tzinfo=None, microsecond=0)


class Repo:
    """Contract (see tests): claim/renew/fail/publish are atomic and owner-checked; readers only see published runs."""

    def migrate(self) -> None: ...
    def ping(self) -> None: ...
    def try_claim(self, run_id: str, nominal: datetime, owner: str, lease_seconds: int, max_attempts: int) -> bool: ...
    def renew(self, run_id: str, owner: str, lease_seconds: int) -> bool: ...
    def put_slot(self, ref: SlotRef, content_type: str, data: bytes) -> None: ...
    def publish(self, run_id: str, owner: str, expected_slots: int) -> bool: ...
    def fail(self, run_id: str, owner: str, cooldown_seconds: int) -> None: ...
    def is_published(self, run_id: str) -> bool: ...
    def latest_published(self) -> tuple[str, datetime, datetime] | None: ...
    def published_slots(self, run_id: str) -> list[SlotRef]: ...
    def history_slots(self, since: datetime, before: datetime) -> list[SlotRef]: ...
    def get_slot(self, run_id: str, slot_id: str) -> SlotBlob | None: ...
    def retain(self, keep_published: int, stale_after: timedelta) -> int: ...


class _Pool:
    def __init__(self, cfg: config.Config) -> None:
        import pymysql
        import pymysql.constants.CLIENT  # noqa: F401
        self._pymysql, self._cfg = pymysql, cfg
        self._queue: queue.LifoQueue = queue.LifoQueue()
        for _ in range(cfg.db_pool_size):
            self._queue.put(None)  # connections are opened lazily

    def _connect(self):
        c = self._cfg
        return self._pymysql.connect(
            host=c.db_host, port=c.db_port, user=c.db_user, password=c.db_password, database=c.db_name,
            charset="utf8mb4", autocommit=False, connect_timeout=10, read_timeout=30, write_timeout=30,
            init_command="SET time_zone='+00:00'", client_flag=self._pymysql.constants.CLIENT.FOUND_ROWS,
        )

    @contextmanager
    def connection(self):
        conn = self._queue.get(timeout=30)
        try:
            if conn is None:
                conn = self._connect()
            else:
                try:
                    conn.ping(reconnect=False)
                except Exception:  # noqa: BLE001 (stale connection: open a new one)
                    conn = self._connect()
            yield conn
            conn.commit()
        except BaseException:
            try:
                if conn is not None:
                    conn.rollback()
            except Exception:  # noqa: BLE001
                conn = None
            raise
        finally:
            self._queue.put(conn)


class MariaRepo(Repo):
    def __init__(self, cfg: config.Config) -> None:
        self.pool = _Pool(cfg)
        self._pymysql = self.pool._pymysql

    def ping(self) -> None:
        with self.pool.connection() as conn, conn.cursor() as cur:
            cur.execute("SELECT 1")

    def migrate(self) -> None:
        """Versioned SQL files (additive only), serialized across replicas with an advisory lock."""
        with self.pool.connection() as conn, conn.cursor() as cur:
            cur.execute("SELECT GET_LOCK('showernow_migrate', 60)")
            if cur.fetchone()[0] != 1:
                raise RuntimeError("could not obtain migration lock")
            try:
                cur.execute("CREATE TABLE IF NOT EXISTS schema_migration ("
                            "version VARCHAR(64) PRIMARY KEY, applied_at DATETIME NOT NULL DEFAULT UTC_TIMESTAMP()"
                            ") ENGINE=InnoDB")
                cur.execute("SELECT version FROM schema_migration")
                done = {row[0] for row in cur.fetchall()}
                for path in sorted(MIGRATIONS_DIR.glob("*.sql")):
                    if path.stem in done:
                        continue
                    for statement in path.read_text(encoding="utf-8").split(";\n"):
                        if statement.strip():
                            cur.execute(statement)
                    cur.execute("INSERT INTO schema_migration (version) VALUES (%s)", (path.stem,))
            finally:
                cur.execute("SELECT RELEASE_LOCK('showernow_migrate')")

    def try_claim(self, run_id, nominal, owner, lease_seconds, max_attempts) -> bool:
        try:
            return self._try_claim(run_id, nominal, owner, lease_seconds, max_attempts)
        except self._pymysql.err.OperationalError as error:
            if error.args and error.args[0] in (1205, 1213):  # lock wait/deadlock: a concurrent claimer won
                return False
            raise

    def _try_claim(self, run_id, nominal, owner, lease_seconds, max_attempts) -> bool:
        with self.pool.connection() as conn, conn.cursor() as cur:
            cur.execute(
                "INSERT IGNORE INTO radar_run (run_id, nominal_time, status, claimed_by, lease_until, attempts) "
                "VALUES (%s, %s, 'claimed', %s, UTC_TIMESTAMP() + INTERVAL %s SECOND, 1)",
                (run_id, nominal, owner, lease_seconds))
            if cur.rowcount == 1:
                return True
            cur.execute("SELECT status, lease_until < UTC_TIMESTAMP(), attempts FROM radar_run "
                        "WHERE run_id = %s FOR UPDATE", (run_id,))
            status, expired, attempts = cur.fetchone()
            if status == "published" or not expired or attempts >= max_attempts:
                return False
            cur.execute("UPDATE radar_run SET status='claimed', claimed_by=%s, attempts=attempts+1, "
                        "lease_until = UTC_TIMESTAMP() + INTERVAL %s SECOND WHERE run_id=%s",
                        (owner, lease_seconds, run_id))
            return True

    def renew(self, run_id, owner, lease_seconds) -> bool:
        with self.pool.connection() as conn, conn.cursor() as cur:
            cur.execute("UPDATE radar_run SET lease_until = UTC_TIMESTAMP() + INTERVAL %s SECOND "
                        "WHERE run_id=%s AND claimed_by=%s AND status='claimed'", (lease_seconds, run_id, owner))
            return cur.rowcount == 1

    def put_slot(self, ref, content_type, data) -> None:
        with self.pool.connection() as conn, conn.cursor() as cur:
            cur.execute(
                "INSERT INTO radar_slot (run_id, slot_id, slot_index, slot_time, content_type, sha256, size, bytes) "
                "VALUES (%s,%s,%s,%s,%s,%s,%s,%s) ON DUPLICATE KEY UPDATE "
                "content_type=VALUES(content_type), sha256=VALUES(sha256), size=VALUES(size), bytes=VALUES(bytes)",
                (ref.run_id, ref.slot_id, ref.slot_index, ref.slot_time, content_type,
                 hashlib.sha256(data).hexdigest(), len(data), data))

    def publish(self, run_id, owner, expected_slots) -> bool:
        with self.pool.connection() as conn, conn.cursor() as cur:
            cur.execute("SELECT status, claimed_by FROM radar_run WHERE run_id=%s FOR UPDATE", (run_id,))
            row = cur.fetchone()
            if row is None or row[0] != "claimed" or row[1] != owner:
                return False
            cur.execute("SELECT COUNT(*) FROM radar_slot WHERE run_id=%s", (run_id,))
            if cur.fetchone()[0] != expected_slots:
                return False
            cur.execute("UPDATE radar_run SET status='published', published_at=UTC_TIMESTAMP() WHERE run_id=%s",
                        (run_id,))
            return True

    def fail(self, run_id, owner, cooldown_seconds) -> None:
        with self.pool.connection() as conn, conn.cursor() as cur:
            cur.execute("UPDATE radar_run SET status='failed', lease_until = UTC_TIMESTAMP() + INTERVAL %s SECOND "
                        "WHERE run_id=%s AND claimed_by=%s AND status='claimed'", (cooldown_seconds, run_id, owner))

    def is_published(self, run_id) -> bool:
        with self.pool.connection() as conn, conn.cursor() as cur:
            cur.execute("SELECT 1 FROM radar_run WHERE run_id=%s AND status='published'", (run_id,))
            return cur.fetchone() is not None

    def latest_published(self):
        with self.pool.connection() as conn, conn.cursor() as cur:
            cur.execute("SELECT run_id, nominal_time, published_at FROM radar_run WHERE status='published' "
                        "ORDER BY nominal_time DESC LIMIT 1")
            row = cur.fetchone()
            return (row[0], row[1], row[2]) if row else None

    def _refs(self, cur) -> list[SlotRef]:
        return [SlotRef(*r) for r in cur.fetchall()]

    def published_slots(self, run_id):
        with self.pool.connection() as conn, conn.cursor() as cur:
            cur.execute("SELECT s.run_id, s.slot_id, s.slot_index, s.slot_time FROM radar_slot s "
                        "JOIN radar_run r ON r.run_id = s.run_id WHERE r.status='published' AND s.run_id=%s "
                        "ORDER BY s.slot_index", (run_id,))
            return self._refs(cur)

    def history_slots(self, since, before):
        with self.pool.connection() as conn, conn.cursor() as cur:
            cur.execute("SELECT s.run_id, s.slot_id, s.slot_index, s.slot_time FROM radar_slot s "
                        "JOIN radar_run r ON r.run_id = s.run_id WHERE r.status='published' AND s.slot_index=0 "
                        "AND r.nominal_time >= %s AND r.nominal_time < %s ORDER BY s.slot_time", (since, before))
            return self._refs(cur)

    def get_slot(self, run_id, slot_id):
        with self.pool.connection() as conn, conn.cursor() as cur:
            cur.execute("SELECT s.content_type, s.sha256, s.bytes FROM radar_slot s "
                        "JOIN radar_run r ON r.run_id = s.run_id "
                        "WHERE r.status='published' AND s.run_id=%s AND s.slot_id=%s", (run_id, slot_id))
            row = cur.fetchone()
            return SlotBlob(row[0], row[1], bytes(row[2])) if row else None

    def retain(self, keep_published, stale_after) -> int:
        with self.pool.connection() as conn, conn.cursor() as cur:
            cur.execute("SELECT run_id FROM radar_run WHERE status='published' "
                        "ORDER BY nominal_time DESC LIMIT 18446744073709551615 OFFSET %s", (keep_published,))
            doomed = [r[0] for r in cur.fetchall()]
            cur.execute("SELECT run_id FROM radar_run WHERE status<>'published' "
                        "AND lease_until < UTC_TIMESTAMP() - INTERVAL %s SECOND", (int(stale_after.total_seconds()),))
            doomed += [r[0] for r in cur.fetchall()]
            for run_id in doomed:
                cur.execute("DELETE FROM radar_slot WHERE run_id=%s", (run_id,))
                cur.execute("DELETE FROM radar_run WHERE run_id=%s", (run_id,))
            return len(doomed)


class MemoryRepo(Repo):
    """Thread-safe fake with the semantics of MariaRepo (single process)."""

    def __init__(self, clock=_now) -> None:
        self.clock, self.lock = clock, threading.RLock()
        self.runs: dict[str, dict] = {}
        self.slots: dict[tuple[str, str], tuple[SlotRef, str, str, bytes]] = {}

    def migrate(self) -> None:
        return None

    def ping(self) -> None:
        return None

    def try_claim(self, run_id, nominal, owner, lease_seconds, max_attempts) -> bool:
        with self.lock:
            now, run = self.clock(), self.runs.get(run_id)
            if run is None:
                self.runs[run_id] = {"nominal": nominal, "status": "claimed", "owner": owner, "attempts": 1,
                                     "lease": now + timedelta(seconds=lease_seconds)}
                return True
            if run["status"] == "published" or run["lease"] >= now or run["attempts"] >= max_attempts:
                return False
            run.update(status="claimed", owner=owner, attempts=run["attempts"] + 1,
                       lease=now + timedelta(seconds=lease_seconds))
            return True

    def renew(self, run_id, owner, lease_seconds) -> bool:
        with self.lock:
            run = self.runs.get(run_id)
            if not run or run["owner"] != owner or run["status"] != "claimed":
                return False
            run["lease"] = self.clock() + timedelta(seconds=lease_seconds)
            return True

    def put_slot(self, ref, content_type, data) -> None:
        with self.lock:
            self.slots[(ref.run_id, ref.slot_id)] = (ref, content_type, hashlib.sha256(data).hexdigest(), data)

    def publish(self, run_id, owner, expected_slots) -> bool:
        with self.lock:
            run = self.runs.get(run_id)
            if not run or run["status"] != "claimed" or run["owner"] != owner:
                return False
            if sum(1 for k in self.slots if k[0] == run_id) != expected_slots:
                return False
            run.update(status="published", published_at=self.clock())
            return True

    def fail(self, run_id, owner, cooldown_seconds) -> None:
        with self.lock:
            run = self.runs.get(run_id)
            if run and run["owner"] == owner and run["status"] == "claimed":
                run.update(status="failed", lease=self.clock() + timedelta(seconds=cooldown_seconds))

    def is_published(self, run_id) -> bool:
        with self.lock:
            return self.runs.get(run_id, {}).get("status") == "published"

    def latest_published(self):
        with self.lock:
            pub = [(r["nominal"], k) for k, r in self.runs.items() if r["status"] == "published"]
            if not pub:
                return None
            nominal, run_id = max(pub)
            return run_id, nominal, self.runs[run_id]["published_at"]

    def published_slots(self, run_id):
        with self.lock:
            if not self.is_published(run_id):
                return []
            return sorted((v[0] for k, v in self.slots.items() if k[0] == run_id), key=lambda s: s.slot_index)

    def history_slots(self, since, before):
        with self.lock:
            out = [v[0] for v in self.slots.values()
                   if v[0].slot_index == 0 and self.is_published(v[0].run_id)
                   and since <= self.runs[v[0].run_id]["nominal"] < before]
            return sorted(out, key=lambda s: s.slot_time)

    def get_slot(self, run_id, slot_id):
        with self.lock:
            v = self.slots.get((run_id, slot_id))
            if v is None or not self.is_published(run_id):
                return None
            return SlotBlob(v[1], v[2], v[3])

    def retain(self, keep_published, stale_after) -> int:
        with self.lock:
            pub = sorted((r["nominal"], k) for k, r in self.runs.items() if r["status"] == "published")
            doomed = [k for _, k in pub[:-keep_published]] if keep_published > 0 else [k for _, k in pub]
            cutoff = self.clock() - stale_after
            doomed += [k for k, r in self.runs.items() if r["status"] != "published" and r["lease"] < cutoff]
            for run_id in doomed:
                self.runs.pop(run_id, None)
                for key in [k for k in self.slots if k[0] == run_id]:
                    del self.slots[key]
            return len(doomed)
