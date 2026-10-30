import unittest
from datetime import UTC, datetime, timedelta, timezone

from radar_ingest import timeutil as t


class TimeUtilTests(unittest.TestCase):
    def test_floor_and_ids(self):
        run = t.floor_step(datetime(2026, 10, 30, 11, 7, 41, tzinfo=UTC))
        self.assertEqual(t.to_id(run), "20261030T1105Z")
        self.assertEqual(t.from_id("20261030T1105Z"), run)
        self.assertEqual(t.to_wms(run), "2026-10-30T11:05:00.000Z")
        self.assertEqual(t.to_iso(run), "2026-10-30T11:05:00Z")

    def test_latest_run_respects_availability_delay(self):
        # 200 s delay: 11:05 counts as published from 11:08:20, not before.
        late = datetime(2026, 10, 30, 11, 8, 20, tzinfo=UTC)
        self.assertEqual(t.to_id(t.latest_run(late, 200)), "20261030T1105Z")
        self.assertEqual(t.to_id(t.latest_run(late - timedelta(seconds=1), 200)), "20261030T1100Z")

    def test_slots(self):
        run = datetime(2026, 10, 30, 11, 5, tzinfo=UTC)
        slots = t.forecast_slots(run)
        self.assertEqual(len(slots), 25)
        self.assertEqual(slots[-1] - run, timedelta(minutes=120))
        self.assertEqual(len(t.history_slots(run)), 12)
        self.assertEqual(t.history_slots(run)[-1], run - timedelta(minutes=5))

    def test_next_wakeup_is_in_the_future_and_on_grid(self):
        now = datetime(2026, 10, 30, 11, 8, 30, tzinfo=UTC)
        wake = t.next_wakeup(now, 200)
        self.assertEqual(wake, datetime(2026, 10, 30, 11, 13, 20, tzinfo=UTC))
        self.assertEqual(t.next_wakeup(wake, 200), wake + t.STEP)

    def test_aware_input_is_converted_to_utc(self):
        local = datetime(2026, 10, 30, 12, 7, tzinfo=timezone(timedelta(hours=1)))
        self.assertEqual(t.to_id(t.floor_step(local)), "20261030T1105Z")


if __name__ == "__main__":
    unittest.main()
