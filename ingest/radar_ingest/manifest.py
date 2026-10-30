"""latest.json: describes only published runs. Paths are relative to /v1/radar/."""

from __future__ import annotations

import json
from datetime import UTC, datetime

from . import config, timeutil
from .repo import Repo, SlotRef

EXTENSION = "webp"
CONTENT_TYPE = "image/webp"


def slot_path(run_id: str, slot_id: str) -> str:
    return f"{run_id}/{slot_id}.{EXTENSION}"


def _entry(ref: SlotRef, run_time: datetime) -> dict:
    slot_time = ref.slot_time.replace(tzinfo=UTC)
    kind = "analysis" if ref.slot_time == run_time.replace(tzinfo=None) else "forecast"
    return {"time": timeutil.to_iso(slot_time), "kind": kind, "path": slot_path(ref.run_id, ref.slot_id)}


def build(repo: Repo, cfg: config.Config) -> bytes | None:
    """Deterministic per DB state (generated_at = publication time), so all replicas answer byte-identically."""
    latest = repo.latest_published()
    if latest is None:
        return None
    run_id, nominal, published_at = latest
    run_time = nominal.replace(tzinfo=UTC)
    history = repo.history_slots(nominal - timeutil.HISTORY_SLOTS * timeutil.STEP, nominal)
    slots = [_entry(r, r.slot_time.replace(tzinfo=UTC)) for r in history]
    slots += [_entry(r, run_time) for r in repo.published_slots(run_id)]
    west, south = config.mercator_to_wgs84(config.BBOX[0], config.BBOX[1])
    east, north = config.mercator_to_wgs84(config.BBOX[2], config.BBOX[3])
    document = {
        "schema": 1,
        "run": run_id,
        "reference_time": timeutil.to_iso(run_time),
        "generated_at": timeutil.to_iso(published_at.replace(tzinfo=UTC)),
        "step_minutes": 5,
        "forecast_horizon_minutes": timeutil.HORIZON_MINUTES,
        "image": {
            "format": CONTENT_TYPE, "width": cfg.width, "height": cfg.height,
            "projection": "EPSG:3857", "bbox": list(config.BBOX),
            "bbox_wgs84": [round(west, 4), round(south, 4), round(east, 4), round(north, 4)],
        },
        "slots": slots,
        "attribution": config.ATTRIBUTION,
        "modification_notice": config.MODIFICATION_NOTICE,
    }
    return (json.dumps(document, separators=(",", ":")) + "\n").encode("utf-8")
