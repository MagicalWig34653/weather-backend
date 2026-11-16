-- Diagnose Radar-Dienst (nur lesen, MariaDB). Aufruf z. B.:
--   mariadb -u <user> -p <datenbank> < docs/diagnose.sql
-- Eine Zeile je Ebene: letztes veroeffentlichtes Bild (UTC), Alter in Minuten und
-- die Laeufe der letzten 6 h nach Status. Ebenen = radar (radar_run) plus alle Ebenen
-- aus LayerCatalog.order (layer_run). Ebenen ohne Daten zeigen NULL; welche per LAYERS
-- aktiv sind, steht in der .env bzw. im Dashboard (Konfiguration).
-- "claimed" = laeuft gerade oder abgebrochen (lease_until pruefen), "failed" = Fehlversuch.
WITH runs AS (
  SELECT 'radar' AS layer, status, nominal_time, published_at, created_at FROM radar_run
  UNION ALL
  SELECT layer, status, nominal_time, published_at, created_at FROM layer_run
), layers (layer) AS (
  VALUES ('radar'), ('pressure'), ('pressure_eu'), ('lightning'), ('clouds'), ('cloudmask'),
         ('cloudmask_vis'), ('cloudmask_vis_eu'), ('temperature_wms'), ('temperature_d2'),
         ('dewpoint_d2'), ('humidity_d2')
)
SELECT l.layer                                                              AS Ebene,
       MAX(r.published_at)                                                  AS letztes_Bild_UTC,
       TIMESTAMPDIFF(MINUTE, MAX(r.published_at), UTC_TIMESTAMP())          AS Alter_Min,
       COALESCE(SUM(r.status = 'published' AND r.created_at >= UTC_TIMESTAMP() - INTERVAL 6 HOUR), 0) AS Laeufe_6h_published,
       COALESCE(SUM(r.status = 'failed'    AND r.created_at >= UTC_TIMESTAMP() - INTERVAL 6 HOUR), 0) AS Laeufe_6h_failed,
       COALESCE(SUM(r.status = 'claimed'   AND r.created_at >= UTC_TIMESTAMP() - INTERVAL 6 HOUR), 0) AS Laeufe_6h_claimed
FROM layers l
LEFT JOIN runs r ON r.layer = l.layer
GROUP BY l.layer
ORDER BY l.layer = 'radar' DESC, l.layer;
