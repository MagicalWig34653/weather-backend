"""Stateless HTTP API: reads published data from the repo, small per-process caches, no access logs."""

from __future__ import annotations

import hashlib
import re
import threading
import time
from collections import OrderedDict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from . import config, manifest
from .repo import Repo

SLOT_ROUTE = re.compile(r"^/v1/radar/(\d{8}T\d{4}Z)/(\d{8}T\d{4}Z)\.webp$")
IMMUTABLE = "public, max-age=31536000, immutable"
LATEST = "public, max-age=30, stale-while-revalidate=30"
MANIFEST_TTL_SECONDS = 5.0


class ByteLRU:
    """LRU bounded by total bytes. Entries are immutable by construction (run/slot ids never change content)."""

    def __init__(self, max_bytes: int) -> None:
        self.max_bytes, self.size, self.items = max_bytes, 0, OrderedDict()
        self.lock = threading.Lock()

    def get(self, key):
        with self.lock:
            if key not in self.items:
                return None
            self.items.move_to_end(key)
            return self.items[key]

    def put(self, key, value: tuple[str, str, bytes]) -> None:
        with self.lock:
            if key in self.items:
                self.size -= len(self.items.pop(key)[2])
            self.items[key] = value
            self.size += len(value[2])
            while self.size > self.max_bytes and self.items:
                _, old = self.items.popitem(last=False)
                self.size -= len(old[2])


class Api:
    """Routing logic independent of the socket layer: returns (status, headers, body)."""

    def __init__(self, repo: Repo, cfg: config.Config, alive=lambda: True, clock=time.monotonic) -> None:
        self.repo, self.cfg, self.alive, self.clock = repo, cfg, alive, clock
        self.blobs = ByteLRU(cfg.cache_max_bytes)
        self._manifest: tuple[float, bytes | None] | None = None
        self._lock = threading.Lock()
        self._flights: dict[tuple, threading.Lock] = {}
        self._flights_lock = threading.Lock()
        self.db_reads = 0

    def _latest(self) -> bytes | None:
        with self._lock:
            now = self.clock()
            if self._manifest is None or now - self._manifest[0] > MANIFEST_TTL_SECONDS:
                self._manifest = (now, manifest.build(self.repo, self.cfg))
            return self._manifest[1]

    @staticmethod
    def _respond(status, headers, body, if_none_match, etag):
        headers = {"ETag": etag, "X-Content-Type-Options": "nosniff", **headers}
        if if_none_match and etag in [t.strip() for t in if_none_match.split(",")]:
            return 304, {k: v for k, v in headers.items() if k != "Content-Type"}, b""
        return status, headers, body

    def _load(self, key):
        """LRU lookup; on a miss exactly one thread reads the DB per key (single flight), others wait for it."""
        hit = self.blobs.get(key)
        if hit is not None:
            return hit
        with self._flights_lock:
            flight = self._flights.setdefault(key, threading.Lock())
        with flight:
            hit = self.blobs.get(key)
            if hit is None:
                self.db_reads += 1
                blob = self.repo.get_slot(*key)
                if blob is not None:
                    hit = (blob.content_type, blob.sha256, blob.data)
                    self.blobs.put(key, hit)
            with self._flights_lock:
                self._flights.pop(key, None)
            return hit

    def handle(self, path: str, if_none_match: str | None) -> tuple[int, dict, bytes]:
        path = path.split("?", 1)[0]
        if path == "/healthz":
            return (200, {"Cache-Control": "no-store"}, b"ok\n") if self.alive() else (503, {}, b"stale\n")
        if path == "/v1/radar/latest.json":
            body = self._latest()
            if body is None:
                return 404, {"Cache-Control": "no-store"}, b""
            etag = '"' + hashlib.sha256(body).hexdigest()[:32] + '"'
            return self._respond(200, {"Content-Type": "application/json", "Cache-Control": LATEST}, body,
                                 if_none_match, etag)
        match = SLOT_ROUTE.match(path)
        if match:
            key = match.groups()
            hit = self._load(key)
            if hit is None:
                return 404, {"Cache-Control": "no-store"}, b""
            content_type, sha, data = hit
            return self._respond(200, {"Content-Type": content_type, "Cache-Control": IMMUTABLE}, data,
                                 if_none_match, f'"{sha}"')
        return 404, {"Cache-Control": "no-store"}, b""


def make_server(api: Api, port: int) -> ThreadingHTTPServer:
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = "radar"
        sys_version = ""

        def _serve(self, head: bool) -> None:
            try:
                status, headers, body = api.handle(self.path, self.headers.get("If-None-Match"))
            except Exception:  # noqa: BLE001 (DB errors must not leak details)
                status, headers, body = 503, {"Cache-Control": "no-store"}, b""
            self.send_response(status)
            for key, value in headers.items():
                self.send_header(key, value)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if not head and status != 304:
                self.wfile.write(body)

        def do_GET(self) -> None:  # noqa: N802
            self._serve(False)

        def do_HEAD(self) -> None:  # noqa: N802
            self._serve(True)

        def log_message(self, *args) -> None:  # no access logs: no IPs, no paths
            return

    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)  # noqa: S104 (inside the container)
    server.daemon_threads = True
    return server
