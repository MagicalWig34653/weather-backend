"""Run and slot arithmetic. A run is the nominal DWD composite time (5-minute grid, UTC)."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

STEP = timedelta(minutes=5)
HORIZON_MINUTES = 120
FORECAST_SLOTS = HORIZON_MINUTES // 5 + 1  # analysis + 24 forecast steps = 25
HISTORY_SLOTS = 12  # past analyses referenced from earlier runs

_ID_FORMAT = "%Y%m%dT%H%MZ"


def floor_step(moment: datetime) -> datetime:
    moment = moment.astimezone(UTC)
    return moment.replace(minute=moment.minute // 5 * 5, second=0, microsecond=0)


def to_id(moment: datetime) -> str:
    return moment.astimezone(UTC).strftime(_ID_FORMAT)


def from_id(identifier: str) -> datetime:
    return datetime.strptime(identifier, _ID_FORMAT).replace(tzinfo=UTC)


def to_wms(moment: datetime) -> str:
    """WMS time with milliseconds; the DWD answers without them with an XML error."""
    return moment.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:00.000Z")


def to_iso(moment: datetime) -> str:
    return moment.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def latest_run(now: datetime, availability_delay_seconds: float) -> datetime:
    """Newest run that should already be available (DWD publishes about 3-3.5 minutes after nominal)."""
    return floor_step(now - timedelta(seconds=availability_delay_seconds))


def forecast_slots(run: datetime) -> list[datetime]:
    return [run + i * STEP for i in range(FORECAST_SLOTS)]


def history_slots(run: datetime) -> list[datetime]:
    """The analyses of the previous runs, oldest first (each is the first slot of its own run)."""
    return [run - i * STEP for i in range(HISTORY_SLOTS, 0, -1)]


def next_wakeup(now: datetime, availability_delay_seconds: float) -> datetime:
    """Next moment at which a new run should be available."""
    delay = timedelta(seconds=availability_delay_seconds)
    return floor_step(now - delay) + STEP + delay
