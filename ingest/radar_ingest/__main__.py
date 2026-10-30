import logging
import sys
import urllib.request

from . import config, repo, service


def healthcheck(cfg: config.Config) -> int:
    """Liveness only (process, HTTP and ingest loop alive); DWD or DB outages must not restart containers."""
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{cfg.http_port}/healthz", timeout=3) as response:  # noqa: S310
            return 0 if response.status == 200 else 1
    except OSError:
        return 1


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s", stream=sys.stdout)
    cfg = config.Config.from_env()
    command = sys.argv[1] if len(sys.argv) > 1 else "serve"
    if command == "healthcheck":
        return healthcheck(cfg)
    if command == "migrate":
        repo.MariaRepo(cfg).migrate()
        return 0
    service.run_forever(cfg)
    return 0


if __name__ == "__main__":
    sys.exit(main())
