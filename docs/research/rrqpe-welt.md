# Dritte Regenkarte Welt: NOAA Enterprise RRQPE

Stand: 17. November 2026. Auftrag: Todolino-Karte 9A5AB666 („Dritte Regenkarte: Welt aus NOAA RRQPE“, Lino 17.11.). Schritt 0: Recherche mit einem Probeabruf (nur lesend, anonym, 4 Dateien; nichts gebaut, nichts deployt). Keine Rechtsberatung.

Kennzeichnung: **[F]** Fakt aus Primärquelle oder eigener Messung, **[A]** Annahme/Schluss, **[?]** unbekannt oder nicht belegt.

## 1. Kurzfazit

- **Machbar und lizenzseitig unkritisch.** Die Daten liegen anonym in einem öffentlichen S3-Bucket, Lizenz „kann nach Belieben genutzt werden“, Namensnennung „NOAA“ erbeten, keine Billigung/Verbindung vortäuschen, veränderte Daten nicht als Original ausgeben [F].
- **Fertiges Weltmosaik** `BLEND/RainRate-Blend-INST`: NetCDF-4, 18000 x 6501 Pixel, 0,02° Lat/Lon, 60°S bis 70°N, alle 10 min, rund 5,3 MB je Datei [F, gemessen].
- **Abdeckung hat Grenzen:** über 60°N sind alle Pixel als „degradiert“ markiert (Skandinavien, Nordmeer); die Region darf in der App nur mit Hinweis erscheinen [F, gemessen]. Nördlich 70°N und südlich 60°S keine Daten [F].
- **Aufwand grob 4 bis 6 Arbeitstage** (HDF5/NetCDF-4-Leser ist die Hauptlücke, Reprojektion ist billig). Rechenlast und Speicher unkritisch (Messung unten) [A].
- **Wichtigste Vorab-Entscheidung:** Bildgröße/Auflösung (Weltbild 4096 px ca. 10 km je Pixel am Äquator, [F] gemessen 227 KB je Slot) und ob die Ebene nur Analyse (ohne Vorhersage) ist. Satellitenschätzung ist deutlich ungenauer als Radar: Hinweis in der App nötig.

## 2. Lizenz und Nutzungsbedingungen

| Punkt | Aussage | Quelle |
|---|---|---|
| Nutzung | „NOAA data disseminated through NODD are open to the public and can be used as desired.“ | [F] [AWS-Registry-Eintrag noaa-ghe](https://registry.opendata.aws/noaa-ghe/), Roh-YAML [open-data-registry](https://github.com/awslabs/open-data-registry/blob/main/datasets/noaa-ghe.yaml) |
| Kommerziell | Nicht ausgeschlossen („as desired“); keine Gebühr, keine Registrierung [F]. Eine ausdrückliche Zeile „kommerziell erlaubt“ gibt es nicht; Schluss aus „as desired“ und Public-Domain-Praxis [A]. | wie oben |
| Weitergabe/Veränderung | Veränderte Daten dürfen nicht als „original, unaltered NOAA data“ bezeichnet werden [F]. Umprojektion und Einfärbung ist eine Veränderung: Wortlaut „Quelle: NOAA, von ShowerNow verarbeitet“ statt „NOAA-Daten“ [A]. | Registry-Eintrag |
| Attribution | „NOAA requests attribution for the use or dissemination of unaltered NOAA data.“ Für veränderte Daten ist sie nicht gefordert; nennen wir trotzdem (Vorgabe der Karte: „NOAA“) [F/A]. | Registry-Eintrag |
| Billigung | „it is not permissible to state or imply endorsement by or affiliation with NOAA“ [F]. | Registry-Eintrag |
| Logo/Name | NWS-Name und Logo sind markenrechtlich geschützt, ohne Genehmigung nicht nutzbar außer zur Kennzeichnung unveränderter Inhalte [F, für NWS]; für NOAA-Logo gleichartig anzunehmen [A]. Daher nur Text „NOAA“, kein Logo (deckt sich mit der Kartenvorgabe). | [weather.gov/disclaimer](https://www.weather.gov/disclaimer) |
| Public Domain | Inhalte von NWS-Seiten „are in the public domain, unless specifically noted otherwise“ [F, NWS]; US-Bundesbehördenwerke sind grundsätzlich gemeinfrei [A, nicht aus Primärquelle der Daten selbst belegt]. | weather.gov/disclaimer |
| Gewährleistung | Daten sind Schätzungen, NetCDF-Metadaten enthalten keinen Lizenzvermerk (`references: N/A`) [F, gemessen]. Ein eigener Haftungsausschluss in der App ist ratsam [A]. | Datei-Attribute |

Offen [?]: Kein Primärdokument explizit „kommerziell“ für genau dieses Produkt; Nachfrage bei nodd@noaa.gov (Datenbereitstellung/Programm) möglich. Die [NODD-Seite](https://www.noaa.gov/information-technology/open-data-dissemination) selbst enthält keine Lizenztexte. Eine Rechtsprüfung der App-Attribution liegt beim Betreiber (wie bei den anderen Quellen).

Hinweis zum Namen: Das Produkt heißt im Bucket „RainRate-Blend“, im NetCDF `RRQPE_INST_GLB`, Algorithmus „Enterprise Rainfall Rate (ERR)“, früher SCaMPR. Es ersetzt das Global Hydro-Estimator-Produkt (GHE) [F, Registry]. Das alte GOES-R-Produkt `ABI-L2-RRQPEF` (Legacy) wird laut [NESDIS-Meldung](https://www.nesdis.noaa.gov/news/retirement-of-goes-r-rainfall-ratequantitative-precipitation-estimation-grrqpe) (1.9.2026) zum 2.11.2026 eingestellt, Nachfolger Enterprise (seit 20.6.2024 für GOES-18/19). Wir nutzen das Enterprise-Blend und sind davon nicht betroffen [A].

## 3. Datenformat und Abruf

### 3.1 Bucket

- Bucket `noaa-enterprise-rainrate-pds`, Region us-east-1, anonym lesbar (`--no-sign-request` bzw. einfacher HTTPS-GET und `?list`-Abfrage ohne Konto) [F, gemessen]. Wurzel: `BLEND/`, `G16/`, `G18/`, `G19/`, `Himawari-9/` [F, gemessen]. Einzelsatelliten-Daten liegen unter `G*/…` und `Himawari-9/…`; relevant ist `BLEND/RainRate-Blend-INST/`.
- Pfad: `BLEND/RainRate-Blend-INST/<JJJJ>/<MM>/<TT>/<HH>/RRQPE-INST-GLB-<n>_v1r1_blend_s<JJJJMMTThhmmsss>_e…_c….nc` [F, gemessen]. Beispiel: `…/2026/11/17/15/RRQPE-INST-GLB-5_v1r1_blend_s202611171550000_e202611171559599_c202611171605404.nc`.
- Benachrichtigung: SNS-Topic `NewEntRainRateL3Object` (nur Lambda/SQS, für uns unpraktisch); Abfrage per Listing je Stunden-Präfix genügt [F/A].
- Aufbewahrung: Bucket-Beginn 2025 [F, Registry-Suche]; Rollfenster/Archiv unbekannt, das Backend braucht nur die letzten Stunden [?].

### 3.2 Dateien und das „GLB-n“-Muster (wichtig)

Jede Nominalzeit (10-min-Raster, `s` = Beobachtungsbeginn, Fenster 9:59 min) wird **mehrfach** veröffentlicht, mit wachsender Satellitenzahl [F, gemessen, Slot 15:50 UTC, 17.11.2026]:

| Datei | Eingänge | Gültige Pixel | `c` (Erstellung) nach `s` |
|---|---|---|---|
| `GLB-2` | GOES-19, GOES-18 | 50 % | +12 min |
| `GLB-3` | + Meteosat-10 | 71 % | +14 min |
| `GLB-4` | + Meteosat-9 | 83 % | +14 min |
| `GLB-5` | + Himawari-9 (Vollversion) | 99,8 % | +15 min |

Nicht jeder Slot hat alle Stufen (z. B. fehlen bei 15:20 GLB-4, bei 15:30 ist `c` für GLB-4/5 +22 min) [F]. **Regel fürs Backend:** je Nominalzeit die höchste vorhandene Stufe nehmen, Vollversion `GLB-5` bevorzugt; ältere Slots nachträglich aktualisieren, solange `GLB-5` fehlt [A]. Latenz Vollversion: 15 bis 27 min nach `s`, also ca. 5 bis 17 min nach Ende des Beobachtungsfensters [F, 16 Dateien am 17.11.]. Satelliten laut Metadaten: GOES-19, GOES-18, Himawari-9, Meteosat-9 („MSG2“), Meteosat-10 („MSG3“), Sensoren ABI/AHI/SEVIRI [F, Attribute].

### 3.3 Inhalt

- Format NetCDF-4/HDF5, gzip-Chunks, Variablen `RRQPE` (int16, Skalierung 0,1, Einheit mm/h, Fill `-9990`, Chunk 813 x 2250) und `DQF` (int8, Datenqualität), 18000 Spalten x 6501 Zeilen [F, gemessen].
- Raster: regelmäßig Lat/Lon (EPSG:4326), 0,02°, `geospatial_lat_min -60`, `lat_max 70`, `lon_min -180`, `lon_max 179.98` [F]. Orientierung nach Plausibilitätsprüfung: Zeile 0 = 70°N, Spalte 0 = 180°W [A, nicht aus Koordinatenvariablen gelesen, Datei hat keine; stimmte bei Stichprobe Deutschland/Mittelmeer mit erwarteten Regenanteilen].
- Größe 3,2 bis 5,4 MB je Datei (Vollversion 5,2 bis 5,35 MB) [F, gemessen]. Bei 144 Slots/Tag ca. 760 MB Download/Tag [A].
- Kein Zeitverlauf/Vorhersage: nur Momentanwert (`INST`); Stunden-/6-/24-h-Summen existieren als Produktnamen, im Bucket sah ich nur `RainRate-Blend-INST` [F, gemessen]. Keine Vorhersage-Slots.

### 3.4 Lücken in der Abdeckung

- Breitenband 60°S bis 70°N [F]. Europa-Ebene `europeBBox` reicht bis 72°N, der Streifen darüber ist leer [A].
- **Hohe Breiten:** Flag `DQF=2` („degraded due to LZA or latitude threshold exceeded“): 100 % der Pixel in 60 bis 70°N × 5 bis 30°E, 26 % der Europa-Box (30 bis 70°N); Deutschland (47 bis 55°N) 0 %; Welt gesamt 10,7 % [F, gemessen, Slot 15:50]. Heißt: Skandinavien, Island, Nordrussland, Kanada nord sind nur eingeschränkt zuverlässig.
- Polarregionen und die Pole fehlen, ebenso Gebiete mit großem Satellitenzenitwinkel am Rand der Scheiben [F/A].
- Zeitliche Lücken: Satelliten-Ausfälle verringern die Stufe (GLB-2 bis GLB-4) [F]; bei fehlendem Himawari-9 fehlt der Westpazifik zeitweise [A].

## 4. Genauigkeit und Grenzen (für den App-Hinweis)

- **Methode [F, [STAR ERR/SCaMPR](https://www.star.nesdis.noaa.gov/smcd/emb/ff/SCaMPR.php)]:** Infrarot- und Wasserdampfkanäle (6,2 bis 12,0 µm) geostationärer Satelliten, kalibriert gegen Mikrowellen-Niederschlag (CPC MWCOMB, Polumlaufer, ca. 2x täglich); Regenerkennung per Diskriminanzanalyse, Rate per Regression, Korrektur bei trockener Unterwolkenluft per Modellfeuchte (GFS). Niederschlag wird aus der **Wolkenoberseite** abgeleitet, nicht gemessen; Radar misst dagegen Niederschlag direkt.
- **Folge [A, aus der Methode, nicht aus Validierungszahlen]:** größere Fehler bei Einzelereignissen als Radar; schwacher und kurzer Niederschlag, warme Regen und Schnee/Eis, Orographie und Konvektion werden schlechter erfasst; Wolkengebiete ohne Regen können als Regen auftauchen (z. B. kalte Cirren) und umgekehrt; Ortsgenauigkeit ca. 2 km (Pixel) plus Parallaxe bei großem Blickwinkel.
- **Validierungszahlen:** Die STAR-Seite nennt keine quantitativen Fehlermaße [F]. ATBD (Kuligowski 2020, v3) und [Kuligowski et al. 2016, J. Hydrometeor. 17](https://doi.org/10.1175/JHM-D-15-0198.1) enthalten sie vermutlich, wurden hier nicht gelesen [?]. Für den App-Hinweis genügt qualitative Formulierung.
- **Metadaten-Monitoring [F]:** 5,5 % Regenpixel weltweit im Probeslot, Maximalrate 85,8 mm/h.
- **Vorschlag App-Text** [A]: „Regen aus Satellitendaten geschätzt (NOAA), ungenauer als Radar. Orts- und Stärkeangaben können abweichen; nördlich 60°N eingeschränkt.“ Als feste Beschriftung der Ebene, nicht nur im Info-Dialog.
- Push „Regen beginnt“ auf dieser Ebene **nicht** empfehlen: keine Vorhersage, Fehlalarm-Risiko, Raster 0,02° statt 1 km-Zellen [A].

## 5. Empfehlung Ebene `radar_world`

### 5.1 Passung zur Pipeline

Die Mechanik „eigene Ebene mit eigener `bbox`/`fixedWidth`“ ist vorhanden (decisions.md, „Bildausdehnung je Ebene“; Obergrenze 4096 px je Seite). Quelle ist kein WMS, sondern ein Dateiabruf: wie bei ICON/EUMETSAT-Ebenen färbt der Server selbst (`MercatorRender`-Muster, siehe europa-radar.md 3.2) [A; Code in diesem Schritt nicht neu gelesen, Angaben nach europa-radar.md].

| Aspekt | Einschätzung |
|---|---|
| **Projektion** | Quelle EPSG:4326 (regelmäßig), Ziel EPSG:3857: reine Zeilen-/Spaltenabbildung, kein Resampling-Aufwand; 60°S bis 70°N passt vollständig in Mercator [F]. |
| **Format-Lücke (Hauptaufwand)** | NetCDF-4/HDF5 mit gzip: der Dienst hat GRIB-Leser, aber keinen HDF5-Leser (europa-radar.md). Optionen: libhdf5/netcdf-c im Image (C-Bibliothek, System-Library-Target in SwiftPM, Linux-Image anpassen) oder eigener Minimal-Parser für diese eine Datei (Superblock, Chunk-B-Tree, gzip über zlib). Empfehlung: libhdf5-Bindung, Parser wäre fragil [A]. Image-Größe und Lizenz (BSD) prüfen. |
| **Zielraster** | `bbox` = Mercator-Extent 180°W bis 180°E, 60°S bis 70°N; bei Breite 4096 ergibt sich 4096 x 1990 (Höhe folgt aus der bbox) [F, gerechnet]. 4096 liegt genau am Limit (App-Limit 4096); 2048 x 995 ist die sparsame Alternative. |
| **Messung (Python/Pillow, nächster Nachbar, Platzhalterpalette mit 15 Klassen, verlustfreies WebP Methode 4, Slot 15:50 UTC)** | 2048 x 995: 73 KB; 4096 x 1990: **227 KB**; Reprojektion 0,04 bis 0,11 s, WebP 0,3 bis 0,6 s, Dateileser 0,4 s. Regenpixel ca. 6 % [F, gemessen auf einem Slot, Wetterlage und Palette beeinflussen das]. Mit Swift-Encoder ähnliche Größenordnung [A]. |
| **Rechenlast** | Ein Lauf alle 10 min, ca. 1 bis 2 s CPU je Slot (Entpacken gzip 117 Mio. Werte ist der größte Posten) und ein 5-MB-Download; deutlich unter der Last der bestehenden Ebenen [A]. Ein Replikat claimt wie sonst den Lauf (DB-Claim). |
| **Speicher** | 227 KB x 6 Slots/h = 1,4 MB/h; Verlauf 6 h ca. 8 MB, 24 h ca. 33 MB in MariaDB (bei 2048 px etwa Drittel) [A]. Der Cache-Standard `CACHE_MAX_MB` 64 MB trägt 24 h, kollidiert aber mit den anderen Ebenen: Verlauf auf 3 bis 6 h begrenzen (analog `CLOUDS_HISTORY_HOURS`). |
| **Traffic App** | Slot 227 KB Weltbild; die App lädt nur den Kartenausschnitt nicht kachelweise, sondern das ganze Bild (wie bei Europa-Ebenen). Bei Zoom auf Stadt grobe 10-km-Pixel (Äquator; bei 50°N ca. 6 km in Ost-West); deshalb 4096 statt 2048 [A]. |
| **Palette/Einheiten** | Rate in mm/h passt zu den bestehenden Intensitätsklassen (anders als OPERA CIRRUS in dBZ); Klassen aus DWD-Palette übernehmen, Schwelle 0,1 mm/h (Datei: Minimum 0,1) [F/A]. Palette für „Satellit“ ggf. etwas abgesetzt (Transparenz) [A]. |
| **DQF** | Pixel mit `DQF&1` (bad) maskieren (0,2 %); `DQF=2` (degradiert) weiterhin zeigen, optional Transparenz erhöhen; Hinweis in der App [A]. |
| **Attribution/Texte** | App-Ebenenbeschriftung „Welt (Satellit, NOAA)“; Quellenzeile „Regendaten: NOAA (aus Satellitendaten geschätzt, von ShowerNow verarbeitet)“; Datenschutztext: Backend → AWS S3 (us-east-1), keine Nutzerdaten [A]. Kein Logo, keine Billigung. |

### 5.2 Aufwandsschätzung [A, nicht gemessen]

1. HDF5/NetCDF-Leser einbinden und Slot lesen (Skalierung, Fill, DQF): 1 bis 2 Tage, Risiko Linux-Image/Swift-Interop.
2. Listing und Auswahl der höchsten GLB-Stufe, Nachaktualisierung, Backfill: 1 Tag.
3. Ebene registrieren (`LayerSpec`, `LAYERS`, Konfigtabellen, Manifest `image{…}`), Palette und DQF-Maske: 1 Tag.
4. Tests (Fixture-Datei verkleinern, Golden-Tests) und Doku: 1 bis 2 Tage.
5. App: Eintrag in der Kartenwahl, Hinweis, Attribution (Apple-Repo, eigene Karte).

### 5.3 Risiken und offene Punkte

- **[?] Stabilität des Produkts:** Bucket erst seit 2025; Dateinamen `v1r1`, Algorithmusversion `v1r1.1` können wechseln; Pfad und Name defensiv per Präfix und Muster lesen, Versionswechsel als Alarm.
- **[?] SLA:** Kein Dienstniveau für den Bucket zugesagt (Open-Data-Programm); Ebene als „Best Effort“, andere Ebenen bleiben unabhängig (wie bei EUMETView-Ausfall, siehe status.md).
- **[?] Lizenzbestätigung „kommerziell“** bei nodd@noaa.gov nachfragen, falls Lino absichern möchte; praktisch geringes Risiko.
- **[?] Qualität in unseren Zielregionen** (Mitteleuropa, Mittelmeer, USA): sinnvoll ist ein Vergleich Satellit gegen DWD-Radar an ein bis zwei Regentagen, bevor die Ebene in der App prominent erscheint; nicht durchgeführt.
- **[?] Erstellungs-Zeitpunkt** der Ebene: Die „Zeit“ der Karte ist das Nominalfenster `s`; Anzeige als Beobachtungszeit (Mitte des Fensters) und tatsächliche Verspätung 15 bis 27 min kommunizieren.
- Der Ingest geht ausschließlich vom Backend aus; die App holt nichts von AWS (kein Standortbezug zu Dritten) [A].
- Entscheidungen, die Lino treffen sollte: Weltbild 4096 oder 2048 px; Verlauf (3/6/24 h); Hinweis fest eingeblendet oder nur im Info-Dialog; Push ausgeschlossen bestätigen.

## 6. Quellen

- [AWS Registry „NOAA GHE / Enterprise Rain Rate“](https://registry.opendata.aws/noaa-ghe/), [Roh-YAML mit Lizenztext](https://github.com/awslabs/open-data-registry/blob/main/datasets/noaa-ghe.yaml)
- [Bucket-Listing noaa-enterprise-rainrate-pds](https://noaa-enterprise-rainrate-pds.s3.amazonaws.com/?delimiter=/) (eigener Abruf 17.11.2026)
- [STAR Enterprise Rainfall Rate / SCaMPR](https://www.star.nesdis.noaa.gov/smcd/emb/ff/SCaMPR.php), [OSPO Enterprise Rain Rate](https://ospo.noaa.gov/products/atmosphere/err/) (nur über Suchtreffer, direkter Abruf 403)
- [NESDIS: Retirement des Legacy-GOES-R-RRQPE](https://www.nesdis.noaa.gov/news/retirement-of-goes-r-rainfall-ratequantitative-precipitation-estimation-grrqpe)
- [NOAA NODD](https://www.noaa.gov/information-technology/open-data-dissemination), [NWS-Disclaimer](https://www.weather.gov/disclaimer)
- Stil/Pipeline-Bezug: `docs/research/europa-radar.md` (Branch `research/europa-radar`), `docs/decisions.md` (Ebenen, Bildausdehnung).

Messdaten stammen aus einem einzelnen Probeslot (15:50 UTC, 17.11.2026) und 16 Dateilisteneinträgen; Rohdaten wurden nicht archiviert.
