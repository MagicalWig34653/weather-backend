# Radar-Container OOM (18. November 2026)

Live (Lino): `showernow_radar.1` auf vps7 um etwa 09:50 mit Exit 137 (OOM-Kill) beendet, Swarm hat neu gestartet. Image `sha-230be1a` (Merge PR #1, `radar_eu`), seit etwa 12 h live. Limit war 512M / 1 CPU, jetzt 768M / 2 CPU. Live-`.env`: `LAYERS=pressure,pressure_eu,lightning,clouds,cloudmask,cloudmask_vis,cloudmask_vis_eu,radar_eu,temperature`, `CACHE_MAX_MB=512`, 2 Replikate. Das DWD-Radar läuft immer (`runIngestLoop`, `Sources/radar/Radar.swift` 423), unabhängig von `LAYERS`.

## Code-Befund (main 230be1a)

- **Alles in einem Prozess:** Jedes Replikat startet Radar-Ingest, Backfill, Push, Warnungen und je Ebene in `LAYERS` eine eigene Schleife (`Radar.swift` 422-429) neben der API. Es gibt kein Rollen-Flag (nur `serve` und `dashboard`, `Radar.swift` 511-523). Der Leader einer Ebene ist das Replikat, das den Lease `layer:<id>` zuerst bekommt (`LayerIngestor.swift` 190); ein Replikat führt oft mehrere Ebenen.
- **Keine Obergrenze für gleichzeitige Konvertierungen:** Die Ebenenschleifen sind unabhängige Tasks; Dekodieren, Umprojizieren und WebP-Kodieren laufen synchron auf dem Concurrency-Pool, also mehrere zugleich (`LayerIngestor.swift` 83-91 und 106-110, `Icon2DIngestor.swift` 138-143).
- **HDF5-Leser:** liest chunkweise und speichert direkt als `Float` (`OdimHDF5.swift` 239 und 257): 3800 x 4400 x 4 B = 67 MB. Es gibt kein Feld mit float64 für das ganze Komposit (die frühere Schätzung „134 MB float64“ trifft nicht zu). Die Datei (3,6 bis 4,1 MB) bleibt während des Lesens im Speicher.
- **LAEA-Tabelle:** einmal je Gitter gebaut und gecacht (`OperaRender.swift` 196-209, höchstens 4 Tabellen, je etwa 22 MB), nicht je Slot neu.
- **Slot-Cache:** LRU nach Nutzbytes `data.count` (`Api.swift` 50-59), Grenze `CACHE_MAX_MB` (`Api.swift` 171); er kannte das Container-Limit nicht.
- **radar_world (PR #2, nicht live):** Der NetCDF-Pfad liest chunkweise direkt ins Zielraster (`NoaaRainRender.swift` 98-138 im Branch `feature/radar-world`); kein Vollfeld 18000 x 6501. Nicht gemessen.

## Messung (ausgeführt, 18.11.2026, macOS arm64)

Methode: `Tests/RadarCoreTests/MemoryProbeTests.swift`, ein Szenario je Prozess (`MEMORY_PROBE=<szenario>`), `swift test -c release -Xswiftc -enable-testing` über `sparsam`. Wert: `phys_footprint` und dessen Spitze (`ledger_phys_footprint_peak`) über der Basis vor dem Szenario. OPERA-Dateien: echte CIRRUS-Komposite 18.11. 08:00, 08:05, 08:10 UTC (ECMWF-Backup-Bucket, 3,6 MB). 2048-px-Ebene: synthetisches PNG 2048 x 2168 mit Grau-Rauschen (11 MB, ungünstiger als echte EUMETView-Bilder), verlustfrei nach WebP wie `cloudmask_vis_eu`.

| Szenario | Spitze über Basis |
| --- | --- |
| OPERA-Slot (Lesen, Tabelle, Filter, Farbe, WebP Methode 4) | 184 MB (erster Slot, mit Tabellenaufbau) |
| 9 OPERA-Slots nacheinander | 184 → 192 MB, danach flach (kein Leck) |
| 2048-px-PNG-Ebene (Dekodieren, WebP verlustfrei) | 234 MB |
| OPERA + 2 x 2048-px-Ebene gleichzeitig | **520 MB** |
| dasselbe mit `HeavyWork` (eine Konvertierung zugleich) | **299 MB** |
| Slot-Cache 64 MB gefüllt (Blobs je 300 kB) | 67 MB real (Zählung 63,8 MB) |
| Slot-Cache 512 MB gefüllt | **535 MB** real (Zählung 511,8 MB, Überhang 4,5 %) |

## Ursache (Bewertung)

- **Belegt:** Mit `CACHE_MAX_MB=512` belegt der volle Cache allein etwa 535 MB, mehr als das alte Limit 512M. Dazu kommen gleichzeitige Konvertierungen von bis zu etwa 520 MB (gemessen, drei schwere Ebenen). Die Summe aus Basis, Cache und Ingest-Spitze passt weder in 512M noch dauerhaft in 768M.
- **Wahrscheinlich, nicht live belegt:** `radar_eu` hat die Spitze um etwa 190 MB je Slot erhöht und die Wahrscheinlichkeit gleichzeitiger Konvertierungen (5-min-Takt) gesteigert; das erklärt den Zeitpunkt (12 h nach dem Merge). Wie voll der Cache live war, ist unbekannt.
- **Nicht gemessen:** glibc-Allokator unter Linux (Arenen, Fragmentierung), Basis des echten Dienstes, echte EUMETView-PNG-Größen.

## Fix (Branch `fix/radar-oom`)

- `HeavyWork` (`Sources/RadarCore/HeavyWork.swift`): prozessweit eine schwere Konvertierung zugleich (OPERA, PNG-Ebenen, ICON-D2), Abrufe bleiben parallel.
- `MemoryBudget` (`Sources/RadarCore/MemoryBudget.swift`): liest das cgroup-Limit (`memory.max`, v1 `memory.limit_in_bytes`) und kappt den Cache auf `max(16 MB, (Limit - 384 MB) / 2)`; Warnung im Log beim Start. Ohne Limit unverändert. 512M → 64 MB, 768M → 192 MB, 1G → 320 MB, 2G → 832 MB.
- `Dockerfile`: `MALLOC_ARENA_MAX=2` (nicht unter Linux gemessen).
- `settings.sh`/`setup.sh`: Speicherlimit bis 16G (768M, 2G, 4096M, 16G erlaubt; 17G, 16385M abgelehnt); `CACHE_MAX_MB` bis 8192; `--check` warnt, wenn `CACHE_MAX_MB` mindestens 60 % des Limits ist.

## Empfehlungen

- **Sofort (Notmaßnahme, ohne Fix):** `CACHE_MAX_MB=128` (Neustart nötig) und Limit 1G. Rechnung: Cache 134 MB real + ungebremste Ingest-Spitze bis 520 MB + Basis (geschätzt 60 bis 100 MB) = etwa 720 bis 760 MB. Bei 768M bleibt das zu knapp; alternativ `radar_eu` aus `LAYERS` nehmen (spart etwa 190 MB Spitze) bis der Fix live ist.
- **Mit Fix:** Limit 768M reicht rechnerisch (Cache auf 192 MB gekappt = 200 MB real + 300 MB Ingest + Basis = etwa 560 bis 600 MB). Soll der Cache 512 MB halten: Limit mindestens 2 x 512 + 384 = 1,4G, also 1536M. Reservierung (`reservations.memory`) etwa 512M.
- **Eigener Ingest-Knoten (16-GB-Node):** heute nicht per Einstellung möglich. `radar-pinned` erbt Umgebung und Limit von `radar` (`deploy/swarm/stack.yaml` 196-208, gleiche Variable `RADAR_MEMORY_LIMIT`), und jedes Replikat bewirbt sich um alle Leases. Nötig wäre ein Code- und Stack-Schalter (z. B. Ingest nur in `radar-pinned`, eigenes Limit `PINNED_MEMORY_LIMIT`); Architekturentscheidung, offen.
