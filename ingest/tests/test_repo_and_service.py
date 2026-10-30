import json
import time
import unittest
import urllib.error
from datetime import UTC, datetime

from radar_ingest import dwd, manifest, server, service, timeutil
from radar_ingest.repo import MemoryRepo, SlotRef
from tests.helpers import db_config, fresh_maria, png_bytes, small_config

RUN = datetime(2026, 10, 30, 11, 5, tzinfo=UTC)
NAIVE = RUN.replace(tzinfo=None)
XML = b"<?xml version='1.0'?><ServiceExceptionReport/>" * 30


class FakeDwd:
    def __init__(self, cfg, failures=None, fail_all=False):
        self.cfg, self.failures, self.fail_all, self.calls = cfg, failures or {}, fail_all, []

    def __call__(self, url: str) -> bytes:
        self.calls.append(url)
        n = len(self.calls)
        if self.fail_all or self.failures.get(n) == "xml":
            return XML
        if self.failures.get(n) == "net":
            raise urllib.error.URLError("boom")
        return png_bytes(self.cfg.width, self.cfg.height, n)


class RepoContract:
    """Behaviour every Repo implementation must show (run against the fake and, if available, MariaDB)."""

    def make_repo(self):
        raise NotImplementedError

    def ingestor(self, repo, owner="a", fetch=None, **cfg_kw):
        cfg = small_config(**cfg_kw)
        return service.Ingestor(cfg, repo, fetch or FakeDwd(cfg), owner, sleep=lambda _s: None), cfg

    def test_claim_is_exclusive_and_renewable(self):
        repo = self.make_repo()
        self.assertTrue(repo.try_claim("r1", NAIVE, "a", 60, 2))
        self.assertFalse(repo.try_claim("r1", NAIVE, "b", 60, 2))
        self.assertTrue(repo.renew("r1", "a", 60))
        self.assertFalse(repo.renew("r1", "b", 60))

    def test_expired_lease_is_taken_over_once_and_attempts_are_capped(self):
        repo = self.make_repo()
        self.assertTrue(repo.try_claim("r1", NAIVE, "a", 1, 2))
        time.sleep(2.1)
        self.assertTrue(repo.try_claim("r1", NAIVE, "b", 1, 2))  # crash takeover
        self.assertFalse(repo.try_claim("r1", NAIVE, "c", 1, 2))  # b holds a valid lease
        self.assertFalse(repo.renew("r1", "a", 60))  # a lost it
        time.sleep(2.1)
        self.assertFalse(repo.try_claim("r1", NAIVE, "c", 1, 2))  # attempts exhausted

    def test_failed_run_has_cooldown(self):
        repo = self.make_repo()
        repo.try_claim("r1", NAIVE, "a", 60, 3)
        repo.fail("r1", "a", 1)
        self.assertFalse(repo.try_claim("r1", NAIVE, "b", 60, 3))
        time.sleep(2.1)
        self.assertTrue(repo.try_claim("r1", NAIVE, "b", 60, 3))

    def test_concurrent_claims_have_a_single_winner(self):
        from concurrent.futures import ThreadPoolExecutor
        repo = self.make_repo()
        with ThreadPoolExecutor(8) as pool:
            wins = list(pool.map(lambda i: repo.try_claim("r1", NAIVE, f"o{i}", 60, 2), range(8)))
        self.assertEqual(sum(wins), 1)

    def test_publish_is_all_or_nothing_and_hides_unpublished_data(self):
        repo = self.make_repo()
        repo.try_claim("20261030T1105Z", NAIVE, "a", 60, 2)
        ref = SlotRef("20261030T1105Z", "20261030T1105Z", 0, NAIVE)
        repo.put_slot(ref, "image/webp", b"data")
        self.assertIsNone(repo.get_slot("20261030T1105Z", "20261030T1105Z"))  # not visible yet
        self.assertFalse(repo.publish("20261030T1105Z", "a", 25))  # incomplete
        self.assertFalse(repo.publish("20261030T1105Z", "b", 1))  # not the owner
        self.assertIsNone(repo.latest_published())
        self.assertTrue(repo.publish("20261030T1105Z", "a", 1))
        self.assertEqual(repo.get_slot("20261030T1105Z", "20261030T1105Z").data, b"data")
        self.assertEqual(repo.latest_published()[0], "20261030T1105Z")

    def test_full_run_manifest_and_history(self):
        repo = self.make_repo()
        for i in range(3):
            ing, cfg = self.ingestor(repo)
            self.assertTrue(ing.process(RUN + i * timeutil.STEP))
        doc = json.loads(manifest.build(repo, cfg))
        self.assertEqual(doc["run"], "20261030T1115Z")
        self.assertEqual(len(doc["slots"]), 2 + 25)  # two earlier analyses are referenced
        self.assertEqual(doc["slots"][0]["path"], "20261030T1105Z/20261030T1105Z.webp")
        self.assertEqual(doc["slots"][0]["kind"], "analysis")
        self.assertEqual(doc["slots"][2]["kind"], "analysis")
        self.assertEqual(doc["slots"][-1]["time"], "2026-10-30T13:15:00Z")
        for slot in doc["slots"]:
            run_id, name = slot["path"].split("/")
            self.assertIsNotNone(repo.get_slot(run_id, name.split(".")[0]), slot)

    def test_second_replica_does_not_fetch_again(self):
        repo = self.make_repo()
        ing_a, cfg = self.ingestor(repo, "a")
        fake_b = FakeDwd(cfg)
        ing_b, _ = self.ingestor(repo, "b", fetch=fake_b)
        self.assertTrue(ing_a.process(RUN))
        self.assertFalse(ing_b.process(RUN))
        self.assertEqual(fake_b.calls, [])

    def test_xml_error_is_retried_bounded_and_failure_publishes_nothing(self):
        repo = self.make_repo()
        cfg = small_config()
        flaky = FakeDwd(cfg, failures={1: "xml", 2: "net", 5: "xml"})
        ing, _ = self.ingestor(repo, fetch=flaky)
        self.assertTrue(ing.process(RUN))
        self.assertEqual(len(flaky.calls), 28)

        dead = FakeDwd(cfg, fail_all=True)
        ing2, _ = self.ingestor(repo, "b", fetch=dead)
        with self.assertRaises(service.RunUnavailable):
            ing2.process(RUN + timeutil.STEP)
        self.assertEqual(len(dead.calls), len(service.PROBE_BACKOFF_SECONDS) + 1)
        self.assertEqual(repo.latest_published()[0], "20261030T1105Z")  # previous publication untouched

    def test_partial_failure_does_not_expose_the_run(self):
        repo = self.make_repo()
        cfg = small_config()
        bad = FakeDwd(cfg, failures={n: "xml" for n in range(5, 90)})
        ing, _ = self.ingestor(repo, fetch=bad)
        with self.assertRaises(service.RunUnavailable):
            ing.process(RUN)
        self.assertIsNone(repo.latest_published())
        self.assertIsNone(repo.get_slot("20261030T1105Z", "20261030T1105Z"))

    def test_retention_keeps_newest_published_runs_with_their_slots(self):
        repo = self.make_repo()
        for i in range(17):
            ing, cfg = self.ingestor(repo, retention_runs=15)
            ing.process(RUN + i * timeutil.STEP)
        self.assertIsNone(repo.get_slot("20261030T1105Z", "20261030T1105Z"))
        self.assertIsNone(repo.get_slot("20261030T1110Z", "20261030T1110Z"))
        self.assertIsNotNone(repo.get_slot("20261030T1115Z", "20261030T1115Z"))
        doc = json.loads(manifest.build(repo, cfg))
        self.assertEqual(len(doc["slots"]), 12 + 25)  # history survives retention of 13 runs

    def test_older_latest_json_stays_resolvable_after_newer_runs(self):
        """Clients may hold a latest.json for up to ~60 s: slots of the last 3 published runs must never 404."""
        repo = self.make_repo()
        manifests = []
        for i in range(20):
            ing, cfg = self.ingestor(repo, retention_runs=15)
            ing.process(RUN + i * timeutil.STEP)
            manifests.append(json.loads(manifest.build(repo, cfg)))
        for doc in manifests[-3:]:  # a client holding the manifest of one of the last 3 runs
            for slot in doc["slots"]:
                run_id, name = slot["path"].split("/")
                self.assertIsNotNone(repo.get_slot(run_id, name.split(".")[0]), (doc["run"], slot))

    def test_manifest_is_identical_for_all_replicas(self):
        repo = self.make_repo()
        ing, cfg = self.ingestor(repo)
        ing.process(RUN)
        self.assertEqual(manifest.build(repo, cfg), manifest.build(repo, cfg))
        a, b = server.Api(repo, cfg), server.Api(repo, cfg)
        etag_a = a.handle("/v1/radar/latest.json", None)[1]["ETag"]
        self.assertEqual(etag_a, b.handle("/v1/radar/latest.json", None)[1]["ETag"])

    def test_http_etag_304_cache_headers_and_routing(self):
        repo = self.make_repo()
        ing, cfg = self.ingestor(repo)
        ing.process(RUN)
        api = server.Api(repo, cfg)
        status, headers, body = api.handle("/v1/radar/20261030T1105Z/20261030T1105Z.webp", None)
        self.assertEqual(status, 200)
        self.assertIn("immutable", headers["Cache-Control"])
        self.assertEqual(headers["Content-Type"], "image/webp")
        self.assertEqual(body[:4], b"RIFF")
        status2, _, body2 = api.handle("/v1/radar/20261030T1105Z/20261030T1105Z.webp", headers["ETag"])
        self.assertEqual((status2, body2), (304, b""))
        status, headers, body = api.handle("/v1/radar/latest.json", None)
        self.assertEqual(status, 200)
        self.assertIn("max-age=30", headers["Cache-Control"])
        self.assertEqual(api.handle("/v1/radar/latest.json", headers["ETag"])[0], 304)
        self.assertEqual(json.loads(body)["run"], "20261030T1105Z")
        for bad in ("/v1/radar/../x", "/v1/radar/20261030T1105Z/nope.webp", "/", "/v1/radar/20990101T0000Z/20990101T0000Z.webp"):
            self.assertEqual(api.handle(bad, None)[0], 404, bad)
        self.assertEqual(api.handle("/healthz", None)[0], 200)
        self.assertNotIn("Set-Cookie", headers)  # stateless, no cookies, no session affinity

    def test_lru_serves_repeated_and_concurrent_requests_with_one_db_read(self):
        from concurrent.futures import ThreadPoolExecutor
        repo = self.make_repo()
        ing, cfg = self.ingestor(repo)
        ing.process(RUN)
        api = server.Api(repo, cfg)
        path = "/v1/radar/20261030T1105Z/20261030T1110Z.webp"
        with ThreadPoolExecutor(16) as pool:
            codes = list(pool.map(lambda _: api.handle(path, None)[0], range(64)))
        self.assertEqual(set(codes), {200})
        self.assertEqual(api.db_reads, 1)

    def test_latest_is_404_before_first_publication(self):
        repo = self.make_repo()
        self.assertEqual(server.Api(repo, small_config()).handle("/v1/radar/latest.json", None)[0], 404)


class MemoryRepoTests(RepoContract, unittest.TestCase):
    def make_repo(self):
        return MemoryRepo(clock=lambda: datetime.now(UTC).replace(tzinfo=None, microsecond=0))


@unittest.skipUnless(db_config(), "set RADAR_TEST_DB_PORT for MariaDB integration tests")
class MariaRepoTests(RepoContract, unittest.TestCase):
    def make_repo(self):
        return fresh_maria()


class MiscTests(unittest.TestCase):
    def test_lru_evicts_by_bytes(self):
        lru = server.ByteLRU(10)
        lru.put("a", ("t", "s", b"123456"))
        lru.put("b", ("t", "s", b"123456"))
        self.assertIsNone(lru.get("a"))
        self.assertIsNotNone(lru.get("b"))

    def test_dwd_url_has_no_location_and_uses_millisecond_times(self):
        url = dwd.build_url(small_config(), RUN, RUN)
        self.assertIn("TIME=2026-10-30T11%3A05%3A00.000Z", url)
        self.assertIn("DIM_REFERENCE_TIME=2026-10-30T11%3A05%3A00.000Z", url)
        self.assertIn("LAYERS=dwd%3ANiederschlagsradar", url)
        self.assertIn("WIDTH=256", url)

    def test_config_rejects_unsafe_retention(self):
        from radar_ingest import config
        with self.assertRaises(ValueError):
            config.Config.from_env({"RETENTION_RUNS": "14"})
        self.assertEqual(config.Config.from_env({"DB_POOL_SIZE": "3"}).db_pool_size, 3)

    def test_secret_is_read_from_file(self):
        import tempfile

        from radar_ingest import config
        with tempfile.NamedTemporaryFile("w", suffix=".txt") as handle:
            handle.write("s3cret\n")
            handle.flush()
            self.assertEqual(config.Config.from_env({"DB_PASSWORD_FILE": handle.name}).db_password, "s3cret")


if __name__ == "__main__":
    unittest.main()
