"""Ingest of one run (claim -> fetch -> validate -> store -> publish) and the scheduling loop.
DWD-friendly: one request chain per 5-minute run across ALL replicas (DB claim), few parallel requests,
bounded retries with exponential backoff and jitter, no retry storm."""

from __future__ import annotations

import logging
import random
import signal
import socket
import threading
import time
import urllib.error
import uuid
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta

from . import config, dwd, manifest, server, timeutil, validate
from .repo import MariaRepo, Repo, SlotRef

log = logging.getLogger("radar_ingest")

RETRYABLE = (validate.InvalidImage, urllib.error.URLError, TimeoutError, ConnectionError, OSError)
# The DWD answers roughly every third GetMap with an XML InvalidDimensionValue error (measured), also for published runs:
# generous but bounded retries. The probe also covers a run that is not published yet (about 3.7 minutes in total).
PROBE_BACKOFF_SECONDS = (5, 10, 20, 40, 60, 90)
SLOT_ATTEMPTS = 6
SLOT_BACKOFF_SECONDS = (3, 6, 12, 20, 20)
FAIL_COOLDOWN_SECONDS = 240
STALE_AFTER = timedelta(hours=1)


class RunUnavailable(Exception):
    pass


class LeaseLost(Exception):
    pass


def _naive(moment: datetime) -> datetime:
    return moment.astimezone(UTC).replace(tzinfo=None)


class Ingestor:
    def __init__(
        self,
        cfg: config.Config,
        repo: Repo,
        fetch: dwd.Fetch,
        owner: str,
        sleep: Callable[[float], None] = time.sleep,
        rng: random.Random | None = None,
    ) -> None:
        self.cfg, self.repo, self.fetch, self.owner, self.sleep = cfg, repo, fetch, owner, sleep
        self.rng = rng or random.Random()  # noqa: S311 (jitter only)

    def _renew(self, run_id: str) -> None:
        if not self.repo.renew(run_id, self.owner, self.cfg.lease_seconds):
            raise LeaseLost(run_id)

    def _fetch_webp(self, run_id: str, run: datetime, slot: datetime, attempts: int, backoffs) -> bytes:
        url = dwd.build_url(self.cfg, run, slot)
        last: Exception | None = None
        for attempt in range(attempts):
            self._renew(run_id)
            try:
                return validate.to_webp(validate.validate_png(self.fetch(url), self.cfg.width, self.cfg.height))
            except RETRYABLE as error:
                last = error
                if attempt + 1 < attempts:
                    self.sleep(backoffs[min(attempt, len(backoffs) - 1)] * (1 + self.rng.random() * 0.5))
        raise RunUnavailable(f"slot {timeutil.to_id(slot)} failed: {type(last).__name__}")

    def process(self, run: datetime) -> bool:
        """Returns True when this replica published the run, False when another replica owns it or it is done."""
        run_id = timeutil.to_id(run)
        if self.repo.is_published(run_id):
            return False
        if not self.repo.try_claim(run_id, _naive(run), self.owner, self.cfg.lease_seconds, self.cfg.max_run_attempts):
            return False
        slots = timeutil.forecast_slots(run)
        try:
            def store(index: int, slot: datetime, data: bytes) -> None:
                ref = SlotRef(run_id, timeutil.to_id(slot), index, _naive(slot))
                self.repo.put_slot(ref, manifest.CONTENT_TYPE, data)

            store(0, slots[0], self._fetch_webp(run_id, run, slots[0], len(PROBE_BACKOFF_SECONDS) + 1,
                                                PROBE_BACKOFF_SECONDS))
            backoffs = SLOT_BACKOFF_SECONDS

            def one(item: tuple[int, datetime]) -> tuple[int, datetime, bytes]:
                return item[0], item[1], self._fetch_webp(run_id, run, item[1], SLOT_ATTEMPTS, backoffs)

            with ThreadPoolExecutor(max_workers=self.cfg.workers) as pool:
                for index, slot, data in pool.map(one, list(enumerate(slots))[1:]):
                    store(index, slot, data)
            if not self.repo.publish(run_id, self.owner, len(slots)):
                raise LeaseLost(run_id)
        except LeaseLost:
            log.info("run %s: lease lost, another replica took over", run_id)
            return False
        except BaseException:
            self.repo.fail(run_id, self.owner, FAIL_COOLDOWN_SECONDS)
            raise
        removed = self.repo.retain(self.cfg.retention_runs, STALE_AFTER)
        log.info("published run %s (%d old runs removed)", run_id, removed)
        return True


def replica_id() -> str:
    return f"{socket.gethostname()[:40]}-{uuid.uuid4().hex[:8]}"


def run_forever(cfg: config.Config) -> None:
    stop = threading.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: stop.set())
    repo = MariaRepo(cfg)
    repo.migrate()
    last_cycle = [time.monotonic()]
    api = server.Api(repo, cfg, alive=lambda: time.monotonic() - last_cycle[0] < 900)
    httpd = server.make_server(api, cfg.http_port)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    ingestor = Ingestor(cfg, repo, dwd.http_fetch(cfg), replica_id())
    failures = 0
    while not stop.is_set():
        last_cycle[0] = time.monotonic()
        run = timeutil.latest_run(datetime.now(UTC), cfg.availability_delay_seconds)
        try:
            ingestor.process(run)
            failures = 0
        except Exception as error:  # noqa: BLE001 (the loop must survive any single failed run)
            failures += 1
            log.warning("run %s not published (%s: %s); consecutive failures: %d",
                        timeutil.to_id(run), type(error).__name__, error, failures)
        wake = timeutil.next_wakeup(datetime.now(UTC), cfg.availability_delay_seconds)
        wake += timedelta(seconds=ingestor.rng.random() * cfg.jitter_seconds)
        if failures > 2:  # additional backoff during longer outages, capped at 10 minutes
            wake += timedelta(seconds=min(60 * (failures - 2), 600))
        while not stop.is_set() and datetime.now(UTC) < wake:
            last_cycle[0] = time.monotonic()
            stop.wait(min(30.0, max(0.5, (wake - datetime.now(UTC)).total_seconds())))
    httpd.shutdown()
    log.info("stopped")
