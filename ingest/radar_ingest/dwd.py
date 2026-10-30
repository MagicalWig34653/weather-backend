"""Minimal DWD WMS GetMap client (one whole-Germany image per slot, no location in any request)."""

from __future__ import annotations

import urllib.request
from collections.abc import Callable
from datetime import datetime
from urllib.parse import urlencode

from . import config, timeutil

Fetch = Callable[[str], bytes]
MAX_READ_BYTES = 4_000_000


def build_url(cfg: config.Config, run: datetime, slot: datetime) -> str:
    query = {
        "SERVICE": "WMS", "VERSION": "1.1.1", "REQUEST": "GetMap",
        "LAYERS": config.LAYER, "STYLES": "", "SRS": "EPSG:3857",
        "BBOX": ",".join(f"{v:g}" for v in config.BBOX),
        "WIDTH": str(cfg.width), "HEIGHT": str(cfg.height),
        "FORMAT": "image/png", "TRANSPARENT": "TRUE",
        "TIME": timeutil.to_wms(slot), "DIM_REFERENCE_TIME": timeutil.to_wms(run),
    }
    return f"{cfg.wms_url}?{urlencode(query)}"


def http_fetch(cfg: config.Config) -> Fetch:
    def fetch(url: str) -> bytes:
        request = urllib.request.Request(url, headers={"User-Agent": cfg.user_agent})  # noqa: S310
        with urllib.request.urlopen(request, timeout=cfg.request_timeout_seconds) as response:  # noqa: S310
            return response.read(MAX_READ_BYTES)
    return fetch
