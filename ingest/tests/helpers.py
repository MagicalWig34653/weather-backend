import io
import os

from PIL import Image

from radar_ingest import config, repo


def png_bytes(width: int, height: int, seed: int = 0) -> bytes:
    image = Image.new("RGBA", (width, height), (255, 255, 255, 0))
    for x in range(40):
        image.putpixel((x, seed % height), (126, 126, 126, 77))
        image.putpixel((x, (seed + 3) % height), (247, 0, 255, 223))
    out = io.BytesIO()
    image.save(out, "PNG")
    data = out.getvalue()
    return data + b"\0" * max(0, 1100 - len(data))  # padding after IEND is ignored by decoders


def small_config(**kw) -> config.Config:
    return config.Config(width=256, **kw)


def db_config() -> config.Config | None:
    """MariaDB integration tests run only when RADAR_TEST_DB_PORT points at a disposable local MariaDB."""
    port = os.environ.get("RADAR_TEST_DB_PORT")
    if not port:
        return None
    return config.Config(
        width=256, db_host="127.0.0.1", db_port=int(port), db_name=os.environ.get("RADAR_TEST_DB_NAME", "radar_test"),
        db_user=os.environ.get("RADAR_TEST_DB_USER", "root"), db_password=os.environ.get("RADAR_TEST_DB_PASSWORD", ""),
    )


def fresh_maria() -> repo.MariaRepo:
    cfg = db_config()
    maria = repo.MariaRepo(cfg)
    with maria.pool.connection() as conn, conn.cursor() as cur:
        for table in ("radar_slot", "radar_run", "schema_migration"):
            cur.execute(f"DROP TABLE IF EXISTS {table}")  # noqa: S608 (fixed names, disposable test DB)
    maria.migrate()
    return maria
