"""Configuration from environment variables (no secrets are needed in stage 1)."""

from __future__ import annotations

import math
import os
from dataclasses import dataclass
from pathlib import Path

# Germany in EPSG:3857 (approx. 5.5-15.6 E, 47.0-55.1 N), as measured in docs/decisions.md.
BBOX = (612257.0, 5942074.0, 1736584.0, 7381298.0)
WMS_URL = "https://maps.dwd.de/geoserver/ows"
LAYER = "dwd:Niederschlagsradar"
ATTRIBUTION = "Quelle: Deutscher Wetterdienst"
MODIFICATION_NOTICE = "Datenbasis: Deutscher Wetterdienst, Rasterdaten bildlich wiedergegeben"


def image_height(width: int) -> int:
    return round(width * (BBOX[3] - BBOX[1]) / (BBOX[2] - BBOX[0]))


def mercator_to_wgs84(x: float, y: float) -> tuple[float, float]:
    radius = 6378137.0
    lon = math.degrees(x / radius)
    lat = math.degrees(2 * math.atan(math.exp(y / radius)) - math.pi / 2)
    return lon, lat


def _secret(env: dict[str, str], name: str, default: str) -> str:
    """Secret from NAME_FILE (Swarm secret, preferred) or NAME; never logged."""
    path = env.get(f"{name}_FILE")
    if path:
        return Path(path).read_text(encoding="utf-8").strip()
    return env.get(name, default)


@dataclass(frozen=True)
class Config:
    db_host: str = "127.0.0.1"
    db_port: int = 3306
    db_name: str = "showernow"
    db_user: str = "showernow"
    db_password: str = ""
    db_pool_size: int = 4
    http_port: int = 8080
    cache_max_bytes: int = 64 * 1024 * 1024
    lease_seconds: int = 150
    max_run_attempts: int = 2
    wms_url: str = WMS_URL
    width: int = 1024
    retention_runs: int = 16
    workers: int = 3
    availability_delay_seconds: float = 200.0
    jitter_seconds: float = 20.0
    request_timeout_seconds: float = 30.0
    user_agent: str = "ShowerNow-radar-ingest/1.0"

    @property
    def height(self) -> int:
        return image_height(self.width)

    @staticmethod
    def from_env(env: dict[str, str] | None = None) -> Config:
        e = os.environ if env is None else env
        d = Config()
        cfg = Config(
            db_host=e.get("DB_HOST", d.db_host),
            db_port=int(e.get("DB_PORT", d.db_port)),
            db_name=e.get("DB_NAME", d.db_name),
            db_user=e.get("DB_USER", d.db_user),
            db_password=_secret(e, "DB_PASSWORD", d.db_password),
            db_pool_size=int(e.get("DB_POOL_SIZE", d.db_pool_size)),
            http_port=int(e.get("HTTP_PORT", d.http_port)),
            cache_max_bytes=int(float(e.get("CACHE_MAX_MB", d.cache_max_bytes / 1048576)) * 1048576),
            wms_url=e.get("WMS_URL", d.wms_url),
            width=int(e.get("IMAGE_WIDTH", d.width)),
            retention_runs=int(e.get("RETENTION_RUNS", d.retention_runs)),
            workers=int(e.get("FETCH_WORKERS", d.workers)),
            availability_delay_seconds=float(e.get("AVAILABILITY_DELAY_SECONDS", d.availability_delay_seconds)),
            jitter_seconds=float(e.get("JITTER_SECONDS", d.jitter_seconds)),
            request_timeout_seconds=float(e.get("REQUEST_TIMEOUT_SECONDS", d.request_timeout_seconds)),
            user_agent=e.get("USER_AGENT", d.user_agent),
        )
        if not 256 <= cfg.width <= 2048:
            raise ValueError("IMAGE_WIDTH must be between 256 and 2048")
        if cfg.retention_runs < 15:
            raise ValueError("RETENTION_RUNS must be at least 15 (12 history analyses, current run, slack)")
        if not 1 <= cfg.db_pool_size <= 10:
            raise ValueError("DB_POOL_SIZE must be between 1 and 10")
        if not 1 <= cfg.workers <= 6:
            raise ValueError("FETCH_WORKERS must be between 1 and 6")
        return cfg
