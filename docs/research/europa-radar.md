# Regenradar Europa: Quellenrecherche

Stand: 17. November 2026. Auftrag: Todolino-Karte 89466514 (Lino: „Regenradar auf Europa erweitern, wenn möglich und wenn es genug öffentliche Quellen gibt“). Nur Recherche (Doku und Produktseiten gelesen), kein Testabruf, kein Code. Keine Rechtsberatung.

Kennzeichnung: **[F]** Fakt aus Primärquelle (URL), **[A]** Annahme/Schluss, **[?]** unbekannt oder nicht belegt.

## 1. Kurzfazit

- Es gibt eine tragfähige Grundlage: das **EUMETNET-OPERA-Komposit** (CIRRUS 1 km/5 min Maximalreflektivität, NIMBUS 2 km/15 min Regenrate), CC BY 4.0, anonym abrufbar über die MeteoGate-API und einen öffentlichen S3-Bucket. Seit 20. Mai 2026 ist das Onboarding auf MeteoGate abgeschlossen (keine Freischaltung mehr nötig).
- Ein Mosaik aus nationalen Quellen wäre deutlich aufwendiger (je Land eigene API, Projektion, Lizenz) und ist für ein Europabild nicht nötig. Nationale Dienste sind nur als Ergänzung sinnvoll (höhere Auflösung, Rate/mm statt dBZ).
- Offen und vor Umsetzung zu klären: **Anonymes Rate-Limit** der MeteoGate-API (keine Zahl veröffentlicht), tatsächliche Dateigrößen, Latenz im Betrieb, Eignung von CIRRUS (dBZ, Maximum, ungefiltertes Rauschen) für die bestehende Farbklassen-Logik der App.

## 2. Quellen

### 2.1 Paneuropäisch

| Quelle | Lizenz | Kommerziell ok | Abdeckung | Takt | Auflösung | Latenz | Zugang | Format |
|---|---|---|---|---|---|---|---|---|
| **OPERA CIRRUS** (Max. Reflektivität, dBZ; seit 07/2024, Produktion Météo-France) | CC BY 4.0 [F] | Ja, mit Namensnennung [F] (HVD-Seite: „reuse permitted for commercial purposes, attribution required“) | Europa ca. 30 W bis 50 E, 32 N bis 70 N, 4400 x 3800 Pixel, Lambert Azimuthal Equal Area [F] | 5 min [F] | 1 km [F] | „weniger als 10 min“ nach Nominalzeit laut Produktblatt [F]; reale Latenz [?] | MeteoGate-API anonym (niedriges Limit, Zahl unbekannt) oder API-Key (kostenlos, Registrierung im Developer Portal); öffentlicher S3-Bucket `openradar-24h` (`--no-sign-request`) [F] | ODIM HDF5, ggf. Cloud-Optimized GeoTIFF [F] |
| **OPERA NIMBUS** (Regenrate mm/h, 1-h-Summe; seit 07/2024, Produktion GeoSphere Austria) | CC BY 4.0 [F] | wie oben [F] | gleiche Domäne, 2200 x 1900 Pixel [F] | 15 min [F] | 2 km [F] | [?] (Zeitfenster -12/+7 min um Nominalzeit) | wie oben | ODIM HDF5, ggf. CoG [F] |
| **EUMETSAT H SAF** (z. B. H63 Niederschlagsrate aus Satellit) | EUMETSAT SAF Data Policy, kostenfrei; Nennung von EUMETSAT/H SAF bei Veröffentlichung [F] | Kommerzielle Weitergabe nicht eindeutig belegt [?] | Satellitenscheibe; H63 ist der IODC-Bereich (Indischer Ozean), also nicht Europa [F] | 15 min | ca. 3 km | [?] | Registrierung H SAF [?] | [?] |

Hinweis zu Lizenzen: Die ORD-Seite nennt für Komposite CC BY 4.0, für OPERA-Einzelradardaten „mit Ausnahmen in den Metadaten“, für nationale Produkte gelten nationale Regeln. Ein Produktblatt (NIMBUS, 2024) beschreibt für externe Nutzer noch den Weg über nationale Dienste/ECOMET-Lizenz oder die Météo-France-API; das ist durch die ORD-/MeteoGate-Seiten (2025/2026) überholt, sollte aber bei EUMETNET bestätigt werden (support.opera@eumetnet.eu, info@eumetnet.eu). Eine Websuche fand zudem einen EUMETNET-Lizenzvertrag (tschechischer Vertragsregister-Eintrag) mit Beschränkung auf Forschung/Lehre; das ist ein bilateraler älterer Vertrag, nicht die offene ORD-Lizenz, zeigt aber, dass die Lizenzlage historisch uneinheitlich war.

Quellen: [EUMETNET OPERA](https://www.eumetnet.eu/activities/observations-programme/current-activities/opera/), [ORD API overview](https://eumetnet.github.io/openradardata-documentation/1-ORD-API-overview/), [ORD API Zugriff](https://eumetnet.github.io/openradardata-documentation/2-ORD-API-discovering-and-accessing-data/), [ORD HVD summary](https://eumetnet.github.io/openradardata-documentation/ORD_HVD_summary/), [CIRRUS-Produktblatt](https://eumetnet.eu/wp-content/uploads/2024/06/OPERA_Max-Reflectivity_Product-Sheet_Ed-2.0.pdf), [NIMBUS-Datenblatt](https://eumetnet.eu/wp-content/uploads/2024/06/NIMBUS_datasheet_composites_1.0_13062024.pdf), [MeteoGate-Doku](https://eumetnet.github.io/meteogate-documentation/2-discovering-and-accessing-data), [H63](https://hsaf.meteoam.it/Products/Detail?prod=H63).

ORD-Zugang im Detail [F, ORD-Doku]: API `https://api.meteogate.eu/eu-eumetnet-weather-radar` (Swagger `/docs`), Komposit-Standort `location_id=0-20010-0-OPERA`, `method=comp`, `standard_name` DBZH/RATE/ACRR; HTTP 204 bei keinen Daten, Header `x-ratelimit-remaining`; S3-Beispielpfad `s3://openradar-24h/2026/06/04/OPERA/COMP/OPERA@20260604T0220@0@DBZH.h5`; 24-h-Rollcache, Langzeitarchiv „TBD“; Ausweich-Endpunkte (Backup-API, ECMWF-S3) dokumentiert; MQTT-Benachrichtigung bei neuen Dateien (Benutzer `everyone`, Port 8884). Dienstbedingungen: kein Missbrauch, übermäßige automatisierte Abfragen vermeiden, Gesetze beachten. Dateigrößen [?] (nur Dritt-Angabe: etwa 0,4 bis 2 MB je Datei, [Earth2Studio-Doku](https://nvidia.github.io/earth2studio/main/modules/generated/data/analysis/OPERA/)).

### 2.2 National (nur Radar-Komposit, soweit belegt)

| Land / Dienst | Lizenz | Kommerziell ok | Abdeckung | Takt | Auflösung | Zugang | Format | Quelle |
|---|---|---|---|---|---|---|---|---|
| **DE DWD** (heutige Quelle) | CC BY 4.0 / GeoNutzV [F, decisions.md] | ja | Deutschland | 5 min | ca. 1 km | WMS ohne Key | PNG/WMS | bestehend |
| **NL KNMI** (5-min-Reflektivitätskomposit NL, Datensatz `radar_reflectivity_composites` 2.0) | CC BY 4.0 [F] | ja (laut Lizenz) | NL und Umgebung (ca. 48,9 bis 56 N, 0 bis 10,9 E), nur 2 Radare [F] | 5 min [F] | [?] | Open-Data-API, Key nötig (anonymer Key, jährlich erneuert, geteiltes Limit; persönlicher Key); Fair-Use-Policy, HTTP 429; Dauerabfragen zur Aktualisierungsprüfung gelten als Missbrauch [F] | HDF5 | [KNMI-Datensatz](https://dataplatform.knmi.nl/dataset/radar-reflectivity-composites-2-0), [Fair use](https://developer.dataplatform.knmi.nl/fair-use) |
| **FR Météo-France** (Radar-Paket, Mosaike) | Licence Ouverte 2.0 (data.gouv-Eintrag) [F] | ja nach Etalab-Lizenz [A] | Frankreich inkl. Übersee | Paket alle 15 min mit drei 5-min-Ständen [F] | [?] | Bearer-Token über Météo-France-API-Portal (Registrierung) [F] | ZIP | [data.gouv](https://www.data.gouv.fr/datasets/package-radar/informations), [API-Doku](https://confluence-meteofrance.atlassian.net/wiki/spaces/OpenDataMeteoFrance/pages/853770430/API+Paquet+Radar+EN) |
| **AT GeoSphere** (INCA/Nowcast, kein reiner Radar-Rohkomposit) | CC BY 4.0 [F] | ja | Österreich | Nowcast 15 min, 3 h Vorhersage, 1 km [F] | 1 km | ohne Key, Limit 5 Anfragen/s und 240/h je Nutzer [F] | API, NetCDF/GeoJSON | [Nowcast](https://data.hub.geosphere.at/en/dataset/nowcast-v1-15min-1km), [Limit](https://dataset.api.hub.geosphere.at/v1/docs/user-guide/request-limit.html), Attribution „Data source: GeoSphere Austria“ |
| **CH MeteoSwiss** (RZC Regenrate, CombiPrecip) | CC BY 4.0, kommerziell ausdrücklich erlaubt, „Quelle: MeteoSchweiz“ [F] | ja [F] | Schweiz | 5 min [F] | [?] | STAC-API, keine Registrierung erwähnt, Rollfenster 14 Tage [F] | ODIM HDF5, LV95 (EPSG:2056), < 1 MB | [Nutzungsbedingungen](https://opendatadocs.meteoswiss.ch/general/terms-of-use), [Produkte](https://opendatadocs.meteoswiss.ch/d-radar-data/d1-precipitation-radar-products) |
| **DK DMI** (Radar-Komposit) | CC BY 4.0 [F] | ja [A] | Dänemark (5 Radare) | 5 min [F] | 500 m [F] | kostenloser API-Key, Abfragen werden mit IP/Key protokolliert, Key-Sperre bei Verstoß [F] | ODIM HDF5, 180 Tage Archiv | [DMI Radar](https://www.dmi.dk/friedata/dokumentation/radar-data), [Terms](https://www.dmi.dk/friedata/dokumentation/terms-of-use) |
| **SE SMHI** (Komposit `comp`) | CC BY 4.0 [F] | ja [A] | Schweden | ca. 5 min [F] | ca. 1 km (Drittquelle) [A] | ohne Key, nur dokumentierte APIs [F] | GeoTIFF/PNG (Werte 0-255) | [SMHI Radar-API](https://opendata.smhi.se/apidocs/radar), [Bedingungen](https://www.smhi.se/en/services/open-data/conditions-of-use-1.33347) |
| **NO MET Norway** (Radar 2.0) | NLOD 2.0 und CC BY 4.0 nach Wahl [F] | ja [A] | Nordeuropa-Komposit (Details [?]) | 5 min (Drittquelle) [A] | ca. 1 km [A] | api.met.no, User-Agent-Pflicht üblich [A, nicht geprüft] | PNG/GeoTIFF [?] | [MET Lizenz](https://docs.api.met.no/doc/License) |
| **FI FMI** | CC BY 4.0 [F] | ja [A] | Finnland | 5 min [F] | [?] | AWS-S3-Bucket `fmi-opendata-radar-geotiff` anonym, auch WFS/WMS (Key [?]) [F] | GeoTIFF | [FMI AWS](https://en.ilmatieteenlaitos.fi/radar-data-on-aws-s3), [Manual](https://en.ilmatieteenlaitos.fi/open-data-manual-radar-data) |
| **CZ ČHMÚ** | im Radar-Dokument nicht gefunden; Drittseite nennt CC BY 4.0 [?] | [?] | Tschechien | 5 min [F] | [?] | opendata.chmi.cz, ohne Key [A] | HDF5 | [Beschreibung](https://opendata.chmi.cz/meteorology/weather/radar/radar_description_en.pdf) |
| **BE RMI/KMI** | Komposit-Lizenz nicht gefunden [?] (AWS-Stationsdaten CC BY 4.0) | [?] | Belgien | [?] | [?] | opendata.meteo.be | [?] | nicht verifiziert |
| **PL IMGW** | nicht gefunden; Hinweise auf restriktive Haltung gegenüber Weitergabe (alte, undatierte Berichte) [?] | wahrscheinlich nein/unklar [?] | Polen | [?] | [?] | [?] | [?] | nicht verifiziert, Anfrage an `licencje@imgw.pl` nötig |
| **UK Met Office** | uneinheitlich: Teile OGL v3, andere nur akademisch/Policy, 5-km-Europa-Komposit „restricted“; AWS-Open-Data „Radar Observations“ als Open Data gelistet [F, CEDA/AWS] | für DataHub 1-km/5-min nicht geklärt [?] | UK (18 Radare) | 5 min | 1 km | DataHub / AWS | HDF5/NIMROD | [AWS-Registry](https://registry.opendata.aws/met-office-uk-radar-observations/) |
| **ES AEMET** | Lizenz im Umbruch (geplant CC BY-SA 4.0), FAQ mit Kopierbeschränkung in älterer Fassung [F/?] | nicht geklärt [?] | Spanien | [?] | nur Bildprodukte („Imagen composición nacional“), keine Rohdaten [F] | OpenData-API, Key per E-Mail [F] | Bild | [datos.gob.es](https://datos.gob.es/en/blog/high-value-meteorological-datasets) |
| **IT DPC** | Echtzeit-Dienste offen, Lizenz des Live-Feeds nicht bestätigt (CC BY-SA nur für ein Archiv der FBK) [?] | [?] | Italien-Mosaik (SRI, VMI) | 5 min [F] | [?] | Websocket/HTTP-Downloader, GitHub `pcm-dpc` | GeoTIFF [A] | [DPC-Karte](https://mappe.protezionecivile.gov.it/en/risks-maps-and-dashboards/radar-map/), [Archiv-Paper](https://arxiv.org/html/2602.15088v1) |

Hinweis: Viele nationale Dienste speisen OPERA bereits; ein nationales Mosaik doppelt diese Arbeit, bringt aber teils höhere Auflösung oder mm/h. Die Lizenz „CC BY“ umfasst Nutzung und Weitergabe auch kommerziell, aber nur mit Namensnennung und Änderungshinweis; jede Quelle muss einzeln in der App genannt werden (bei Mosaik: bis zu ca. 10 Zeilen Quellenvermerk, [A]).

## 3. Passung zur bestehenden Pipeline

Gelesen: `Layers.swift`, `ImagePipeline.swift`, `LayerIngestor.swift`, `Config.swift`, `PushModels.swift`.

### 3.1 Ist-Stand

- **Radar heute (DWD):** WMS-GetMap `dwd:Niederschlagsradar` in EPSG:3857, Deutschland-bbox `[612257, 5942074, 1736584, 7381298]`, Standardbreite **1024 px** (`IMAGE_WIDTH`, zulässig 256 bis 2048), Höhe 1311, 5-min-Raster, `HISTORY_HOURS` 48, `RETENTION_RUNS` 16, verlustfreies WebP (Palette bleibt exakt, 259 bis 260 verschiedene RGBA-Werte), Cache `CACHE_MAX_MB` 64 MB, Ablage in MariaDB (`radar_slot` MEDIUMBLOB), Ingest über DB-Claim je Lauf mit Lease.
- **Push:** Das Push-Raster ist das 1024-px-Ingest-Raster (`PushGrid.width = 1024`; `PUSH_ENABLED=true` erzwingt `IMAGE_WIDTH=1024`, `Config.swift:284`). Der Server dekodiert die gespeicherten WebP-Slots (`ImagePipeline.decodeWebP`) und klassifiziert Pixel über die DWD-Palette (15 Stufen). Zelle = Pixel, die App rechnet die Zelle lokal aus der Mercator-Position; der Server sieht keine Koordinate. Regionen: Umkreise auf 3x3-Zellblöcke gerundet, Limits 3 Regionen/Installation, 8000 Zellen/Installation, 50 Mio. Regionszellen serverweit.
- **Es gibt bereits Europa-Ebenen:** `RadarConstants.europeBBox` (-25 bis 45 E, 30 bis 72 N, EPSG:3857, 2048 x 2168 px, ca. 2,4 km/px bei 50 N) für `pressure_eu`, `cloudmask_vis_eu` u. a. (EUMETSAT/DWD-WMS). Eine Europa-Radarebene könnte dieses Raster und die „eigene Bildausdehnung je Ebene“-Mechanik (`LayerSpec.bbox`/`fixedWidth`) wiederverwenden.

### 3.2 Was ein OPERA-Komposit ändert

| Aspekt | Wirkung | Einstufung |
|---|---|---|
| **Quellformat/Projektion** | OPERA liefert ODIM HDF5 in Lambert Azimuthal Equal Area, keine fertige Bildkachel. Nötig: HDF5-Leser (der Dienst hat bereits einen eigenen GRIB-Leser und libbz2, aber keinen HDF5-Leser; libhdf5-Abhängigkeit im Image oder eigener Parser), Umprojektion nach EPSG:3857, Einfärbung nach Palette. Mit ICON-D2 existiert ein Muster („Server färbt“, `MercatorRender`). | [A] 3 bis 6 Arbeitstage, Hauptrisiko: HDF5 unter Linux/Swift |
| **Bildgröße** | Auf Europa-bbox 2048 x 2168 (2,4 km/px) verliert man die 1-km-Auflösung von CIRRUS (4400 x 3800). 1 km in Mercator-Europa ergäbe ca. 7000 x 7500 px, über dem App-Limit 4096 px je Seite (`maxPixelsPerSide`). Realistisch: gröbere Europa-Ebene 2048 px plus Deutschland weiterhin über DWD. | [F] Limit aus Code; [A] Entscheidung nötig |
| **Cache/Speicher** | Gemessen für andere Ebenen: `pressure_eu` ca. 170 KB/Slot, `cloudmask_vis_eu` 550 bis 840 KB/Slot. Radar ist auf 2048 x 2168 vermutlich 150 bis 500 KB/Slot (viel transparente Fläche, wenige Farben, verlustfrei) [A, nicht gemessen]. Bei 48 h x 12 Slots/h = 576 Slots wären das etwa 90 bis 290 MB je Replikat-Cache (Standard 64 MB!) und DB-Speicher. Verlauf 48 h bei Europa wohl auf 3 bis 6 h kürzen (wie `CLOUDS_HISTORY_HOURS`, max. 24 h) oder nur Cache-Teilmenge. | [A] Messung nötig |
| **Ingest-Last** | Ein weiterer Lauf alle 5 min: Download 0,4 bis 2 MB (Dritt-Angabe), HDF5 lesen, Umprojektion 8 bis 16 Mio. Pixel, WebP-Encoding. Bei ICON-D2 gemessen 0,25 s je Slot mit WebP-Methode 4 (1024 x 1311); Europa ca. 3 bis 4x Pixel, also grob 1 s [A]. Unkritisch gegenüber der bestehenden Last, aber Verlustfreies WebP Methode 6 kostet 3,4 s und muss vermieden werden (Methode 4). | [A] gering |
| **Traffic** | Außen: Ein Europa-Slot ist größer als ein Deutschland-Slot; die App lädt nur sichtbare Ebene und Zeitschritte. Innen: eine Anfrage alle 5 min an MeteoGate/S3 genügt (MQTT-Hinweis oder Zeitraster); das liegt weit unter plausiblen Limits, das anonyme Limit selbst ist aber [?]. Empfehlung: kostenlosen API-Key registrieren oder den öffentlichen S3-Bucket nutzen (kein Limit dokumentiert). | [?] Limit |
| **Push „Regen beginnt“** | Push rechnet auf dem Deutschland-Raster, DWD-Palette, Zellen ca. 1 km (Mittelpunkte der Umkreise auf 3x3 gerundet, ca. 2 km). Außerhalb Deutschlands gibt es heute kein Raster, Standorte im Ausland werden nicht unterstützt (Zelle nicht darstellbar). Für Europa gäbe es entweder (a) ein zweites Push-Raster auf der Europa-bbox (2,4 km, 4 bis 5x Zellen, andere Zellindizes: **API-/Datenmodell-Änderung**, `push_sub.cell_x/cell_y` sind an 1024 gebunden, `PushGrid.version` erhöhen), oder (b) Push bleibt nur Deutschland (empfohlen für Schritt 1). Zusätzlich sind CIRRUS-Werte dBZ (Maximum, rauschanfällig; Schwellenempfehlung 0,12619 dBZ ≈ 0,01 mm/h), die Palette und Klassen (15 Stufen) müssten neu festgelegt werden; NIMBUS (mm/h) passt besser zu den bestehenden Intensitätsklassen. | [F] Code; [A] Änderungsumfang 5 bis 10 Tage bei Push-Europa |
| **Regionen-Budget** | 50 Mio. Regionszellen serverweit, 8000/Installation: gelten in Zellen. Bei 2,4-km-Zellen deckt dieselbe Zellzahl 5,8x mehr Fläche, die Limits wären in km² anders zu lesen; Rechenzeit linear zur Zellzahl. Bei Push nur Deutschland: unverändert. | [A] |
| **Datenschutz** | Standort bleibt lokal in der App, der Server kennt nur Zellen (außerhalb Deutschlands bei 2,4 km noch gröber, also eher weniger identifizierend). Neu: Abrufe der App für Europa-Slots geben dem Server nichts Neues. Neu im Datenschutztext: Datenquellen EUMETNET OPERA/MeteoGate als Empfänger der Server-Abrufe (nur Backend → Quelle, keine Nutzerdaten) und Quellenvermerk. Ein Push-Abo mit Mittelzelle in Spanien/Polen etc. wäre eine Zelle in einem anderen Land: gleiche Rechtsgrundlage, aber Hinweis „Abdeckung/Qualität“. | [A], keine Rechtsberatung |
| **Attribution** | „Quelle: EUMETNET OPERA“ plus Hinweis zur Verarbeitung (Umprojektion, Einfärbung). Konkrete Wortlaut-Vorgabe fand sich nicht [?]; bei EUMETNET nachfragen. DWD-Vermerk bleibt für Deutschland. | [?] |

## 4. Datenqualität und Lücken

- **Qualität [F, [EURADCLIM](https://essd.copernicus.org/articles/15/1441/2023/), Overeem et al. 2023, 2-km-Archiv, vor CIRRUS/NIMBUS]:** Unterschätzung der Niederschlagssumme um Zehnerprozente, räumlich und zeitlich uneinheitlich; Clutter und Störstrahlung (Speichen, defektes spanisches Radar mit über 50 mm/24 h), Strahlabschattung sichtbar in Teilen Österreichs, Italiens und Nordwest-Spaniens; Auflösung nimmt mit Radarentfernung ab (jenseits ca. 115 km unter 4 km² effektiv); über See schwächer. Zu Gebirgen allgemein variable Leistung, keine Zahl [F].
- **CIRRUS-Hinweis [F, Produktblatt]:** Nicht alle Eingangsdaten sind gefiltert; niedrige Reflektivität (Rauschen) ist nicht überall entfernt, daher wird ein Schwellwert empfohlen. Spanien liefert nur 10-min-Daten und wird per Lucas-Kanade zeitlich nach vorn extrapoliert. Modernisierung: Rumänien abgeschlossen (neue Daten ab Herbst 2024), Spanien laufend, Griechenland in Vorbereitung.
- **Länder ohne/mit schwachem Beitrag:** Die ORD-Dokumentation nennt keine Länderliste; „nicht alle OPERA-Mitglieder sind EU-Mitglieder, manche EU-Staaten nutzen nur nationale Schnittstellen“ [F]. Das Kompositgebiet enthält Nodata dort, wo nie Radar strahlte [F, EURADCLIM]. Aktuelle Lücken (Länder, Zeitreihen) lassen sich nur durch Beobachtung des Produkts feststellen: [?] offen. Aus der Literatur: Beiträge aus Österreich und Italien waren in älteren Kompositversionen lückenhaft [F, EURADCLIM, Stand Datenerzeugung 2023].
- **Nowcasting/Vorhersage:** Im OPERA-Komposit selbst **nicht** vorhanden (nur Beobachtung) [F]. Nationale Nowcasts: GeoSphere Austria (15 min, 3 h, 1 km) [F]; MeteoSwiss (Short-term-Forecast-Seiten vorhanden, nicht geprüft). Die bestehende App „Regen in N min“ nutzt keine Radarvorhersage, sondern DWD-Radar-Slots (Analyse plus Vorhersage-Slots des DWD, soweit im Dienst vorhanden); ein europäischer Ersatz wäre ein eigenes Projekt (z. B. optischer Fluss) [A].

## 5. Empfehlung

| Option | Inhalt | Aufwand grob | Risiken |
|---|---|---|---|
| **A (empfohlen): nur OPERA-Komposit als zusätzliche Ebene `radar_eu`** | Eigene Ebene auf Europa-bbox 2048 px, Quelle NIMBUS (mm/h, passt zu Intensitätsklassen) oder CIRRUS (dBZ, 1 km, Rauschen); Verlauf kurz (3 bis 6 h); Push unverändert nur Deutschland; Deutschland-Radar bleibt DWD (höhere Qualität, Palette fix). Eine Quelle, eine Lizenz, eine Attribution. | 5 bis 8 Tage Backend (HDF5-Leser, Umprojektion, Palette, Ebene, Tests); App-Anzeige separat | Anonymes Rate-Limit unbekannt (Key/S3 nutzen), Qualität an Rändern/Gebirge, Dateigrößen, kein Nowcast; Quellenwortlaut offen; MeteoGate-Betrieb noch jung („external testing“ ab Okt. 2025, MeteoGate-Integration 20. Mai 2026) |
| **B: OPERA plus nationale Ergänzung** | wie A, dazu nationale Quellen mit offener Lizenz und hoher Auflösung (z. B. DMI 500 m, MeteoSwiss, GeoSphere, FMI, SMHI) als Verfeinerung je Land; Deutschland weiter DWD. | A plus je Land 3 bis 5 Tage und laufende Pflege, 6+ Attributionen | viele Formate/Projektionen (LV95, Lambert, DK), uneinheitliche Limits und Keys; Lizenzlage bei BE/PL/ES/UK/IT/CZ ungeklärt; Naht-Artefakte (Farbe/Skala); Wartungsaufwand hoch |
| **C: nicht erweitern** | Deutschland bleibt; Europa nur als bestehende Satelliten-/Druckebenen. | 0 | Ziel „Europa-Radar“ unerfüllt |

Empfehlung: **A, mit Schritt 0 vor jeder Programmierung**: (1) Live-Testabruf von CIRRUS/NIMBUS über S3 oder MeteoGate (HEAD/GET einer Datei, Größe und Alter messen), Rate-Limit-Header lesen, API-Key registrieren; (2) bei EUMETNET (`support.opera@eumetnet.eu`) Attribution und die gewerbliche Weitergabe in einer App kurz bestätigen lassen; (3) Auswahl NIMBUS vs. CIRRUS anhand eines Beispielbilds. Erst danach Umsetzung. Push für Europa als eigene, spätere Entscheidung (Datenmodell ändert sich).

## 6. Unbeantwortet / nicht geprüft

- Keine Testabrufe, keine Dateigrößen, keine echte Latenz; Zahlen zu Dateigröße (0,4 bis 2 MB) und zu WebP-Größe/Cache sind Dritt-Angaben bzw. Schätzungen.
- Anonymes und Key-Limit von MeteoGate nicht veröffentlicht (Developer Portal verlangt Anmeldung, nicht abgerufen). Nutzungsbedingungen von MeteoGate nur sinngemäß aus der Doku, nicht im Volltext.
- Lizenztexte nur gelesen, nicht juristisch bewertet; CZ, BE, PL, UK (DataHub), ES, IT, NO (Details), KNMI-Auflösung nicht verifiziert. Quellenvermerk für OPERA nicht vorgegeben gefunden.
- Aktuelle Länderlücken im OPERA-Komposit (2026) nicht ermittelt.
- Ob der Deutschland-Verlauf (48 h) auf Europa übertragen werden soll, ist Produktentscheidung.
- Keine Prüfung der HDF5-Bibliothek unter Swift/Linux, keine Messung der Ingest-Zeit.

## 7. Schritt 0: Probeabruf (17. November 2026, ca. 17:30 MEZ)

Freigabe: Variante A (nur OPERA, Ebene `radar_eu`). Geprüft mit je einem GET auf eine CIRRUS-Datei (`DBZH`), mehreren anonymen Listings und einem lokalen Python-Lauf mit h5py/pyproj. Probedatei nicht im Repo. Nicht geprüft ist alles unter „Offen“.

**Geprüft**

- **Bucket-Zugang:** Das Beispiel `aws s3 ... --no-sign-request` aus der Doku braucht den Endpunkt `https://s3.waw3-1.cloudferro.com/` (nicht AWS; `openradar-24h.s3.amazonaws.com` liefert NoSuchBucket). Anonymes Listing und Download per HTTPS funktionieren ohne Tool. Der Haupt-Bucket `openradar-24h` (CloudFerro) enthielt beim Abruf nur Einzelradar-Dateien aus 2026/10 (9. und 27.), **keine** Komposite und nichts vom 17.11. Aktuelle Komposite lagen im Backup-Bucket `https://object-store.os-api.cci1.ecmwf.int/openradar-24h-backup/` (ECMWF, Ceph). Der Haupt-Bucket ist also als Quelle unzuverlässig, bis EUMETNET das klärt; Backup-Bucket oder MeteoGate-API einplanen.
- **Pfad/Name:** `YYYY/MM/DD/OPERA/COMP/OPERA@YYYYMMDDTHHMM@0@DBZH.h5` (Nominalzeit UTC, 5-min-Raster), je Zeitpunkt zusätzlich `.tiff` (GeoTIFF/CoG-Variante). `RATE` (NIMBUS) und `ACRR` nur im 15-min-Raster, ACRR-Zeit = Intervallende. Listing mit `list-type=2&prefix=...` ohne Anmeldung möglich.
- **Dateigröße (DBZH):** HDF5 ca. 4,04 MB (4 Dateien: 4,03 bis 4,07 MB), TIFF ca. 5,1 MB. Zum Vergleich RATE-h5 ca. 1,9 MB, ACRR-h5 ca. 2,5 MB. Die Dritt-Angabe 0,4 bis 2 MB war für CIRRUS zu niedrig. Download der 4 MB-Datei vom Heimnetz: 3,1 s. Bei 12 Abrufen/h also ca. 48 MB/h, ca. 1,2 GB/Tag Eingang.
- **Latenz:** Bucket-Zeitstempel (LastModified) minus Nominalzeit: DBZH ca. 4,4 bis 4,5 min konstant (z. B. 16:00 -> 16:04:28, 16:25 -> 16:29:23). RATE/ACRR ca. 10 min. Dafür gilt: erster Versuch ca. 5 min nach Nominalzeit, bei 404 nach 30 bis 60 s erneut.
- **Ablauf der Daten:** Lebenszyklusregel `10-days-lifecycle` im Backup-Bucket (Ablaufdatum der Probedatei 28.11.), die Doku nennt „24 h“; Langzeitarchiv weiterhin TBD. Nur der aktuelle Stand zählt für uns.
- **HDF5-Struktur (ODIM H5 2.4, `object=COMP`, `product=MAX`):** `dataset1/data1/data` mit Form (4400 Zeilen, 3800 Spalten), **float64** (nicht uint8), gzip, Chunks 760 x 880. `dataset1/data1/what`: `quantity=DBZH`, `gain=1.0`, `offset=0.0` (Werte stehen schon in dBZ), `nodata=-9999000.0`, `undetect=-8888000.0`. Zusätzlich `quality1` (gleiche Form, Qualitätsindex). Zeit in `dataset1/what` (`startdate/starttime`, `enddate/endtime`) und `what` (`date/time`). `how/license` = CC BY 4.0; `how/nodes` listet die beitragenden Radare; `how/comment` weist auf Lucas-Kanade-Advektion bei Météo-France hin (spanische Daten extrapoliert).
- **Projektion:** `where/projdef = +proj=laea +lat_0=55.0 +lon_0=10.0 +x_0=1950000.0 +y_0=-2100000.0 +units=m +ellps=WGS84`, `xscale=yscale=1000 m`, Ursprung = Pixel oben links (Zeile 0 = Norden). Pixelposition: `col = x/1000`, `row = -y/1000` (x,y aus der LAEA-Projektion mit obigem projdef). Geprüft: Ecken stimmen mit `UL/LL/LR/UR_lat/lon` überein (UL -39,54 E / 67,02 N, LL -10,43 E / 31,75 N).
- **Anteile im Probebild (16:25 UTC, Mitte November):** 48,4 % nodata (außerhalb der Radarabdeckung), 34,2 % undetect, 17,4 % Messwert; dBZ von -32 bis 73,5; 206 verschiedene Werte. Rauschen: -32 dBZ im Datensatz, Schwelle (0,12619 dBZ) nötig; 970 000 Pixel >= 20 dBZ.
- **Umprojektion getestet (Python, pyproj + numpy, nur Lookup):** Nearest-Neighbor auf das bestehende Europa-Mercator-Raster (2048 x 2168, bbox -25 bis 45 E / 30 bis 72 N): Koordinatentransformation 0,27 s, Lookup 0,10 s. 82 % des Rasters liegen im OPERA-Gitter, 13 % davon mit Messwert. Das reicht als Machbarkeitsbeleg; Bildqualität (Aliasing bei 1 km -> 2,4 km) noch nicht beurteilt.
- **Lizenz:** `how/license` in der Datei nennt CC BY 4.0, `publisher_name` EUMETNET, `creator_name` Meteo France. Passt zur ORD-Doku; Namensvorgabe für die Quellenangabe weiterhin nicht gefunden (Vorschlag: „Quelle: EUMETNET OPERA (CC BY 4.0), Daten umprojiziert und eingefärbt“).
- **Rate-Limit:** Für S3 (beide Buckets) kein Limit dokumentiert und bei 8 Anfragen nicht aufgefallen (kein Ratelimit-Header, kein 429). MeteoGate nur nach Doku: anonyme Abfragen mit niedrigem Limit, Header `x-ratelimit-remaining`; nicht abgerufen.

**Empfehlung Umprojektion LAEA nach Web-Mercator**

- **Eigener Code (empfohlen) statt gdalwarp.** Gründe: Der Dienst ist reines Swift im Container ohne GDAL; GDAL (ca. 100+ MB mit PROJ, HDF5, Python/CLI) wäre eine neue schwere Abhängigkeit, und die Aufgabe ist klein und fest: Ziel-Raster ist konstant (Europa-bbox), die Quellprojektion ist fest. Vorgehen: Einmalig je Ziel-Pixel (2048 x 2168 = 4,4 Mio.) die Quellzeile/-spalte berechnen (LAEA-Formeln, kugel/Ellipsoid, ca. 30 Zeilen) und als Index-Tabelle (Int32, ca. 18 MB) cachen. Pro Slot dann nur `out[i] = src[idx[i]]` mit Schwelle und Palette: Millisekunden. Für 1 km -> 2,4 km besser Max- oder Bilinear-Filter statt Nearest (Gitter 1 km, Ziel 2,4 km: Nearest verliert Zellen).
- **HDF5 lesen** bleibt das eigentliche Risiko (kein HDF5-Leser im Dienst): Bibliothek libhdf5 im Image oder minimaler eigener Leser für genau dieses Layout (gzip/Chunked, float64). Die TIFF-Variante (`.tiff` neben jeder `.h5`) ist eine Alternative: 5,1 MB, aber GeoTIFF/COG-Leser nötig und auch größer; vor einer Entscheidung klären, ob TIFF bereits Mercator ist (nicht geprüft).
- **gdalwarp** wäre nur für einen Offline-Test oder eine Referenzprüfung sinnvoll (Ergebnisvergleich der eigenen Index-Tabelle), nicht im Betrieb.

**Offen (nicht geprüft)**

- NIMBUS (`RATE`, 2 km, mm/h) nicht heruntergeladen/geöffnet; nur Größe und Zeitstempel aus dem Listing. Struktur/Nodata-Werte von RATE offen.
- Inhalt der `.tiff`-Dateien (Projektion, Kompression) nicht geöffnet.
- MeteoGate-API (anonym und mit Key): nicht aufgerufen; echtes Rate-Limit offen. MQTT nicht geprüft.
- Warum der CloudFerro-Haupt-Bucket keine aktuellen Komposite enthält (Wartung, Umzug, Filter?), offen; EUMETNET fragen (support.opera@eumetnet.eu).
- Langzeitverhalten der Latenz (Ausreißer, Ausfälle, Lücken einzelner Länder), nur ca. 10 Zeitpunkte gesehen.
- Bildqualität nach Umprojektion und Farbklassen für dBZ; Rauschfilterung.
- Kein Build, Test oder Docker ausgeführt.

## 8. Schritt 0, Nachtrag: offizielle Doku (Speicher, Rate, Attribution, LibreWXR)

Stand 17. November 2026. Quellen: ORD-Doku (`eumetnet.github.io/openradardata-documentation/`, Seiten „API overview“ und „Discovering and accessing data“), MeteoGate-Doku (`eumetnet.github.io/meteogate-documentation/2-discovering-and-accessing-data`, Abschnitt „Attribution and Reuse“), LibreWXR-Repo (`src/librewxr/sources/regional/europe/radar/opera/README.md`, `source.py`, nur gelesen, nichts übernommen). Keine Mail an EUMETNET gesendet.

**1. Welcher Speicher ist offiziell?**
- [F] Die ORD-Doku zeigt auf beiden Seiten einen Hinweis „ORD Backup“: Wegen eines Problems beim Cloud-Anbieter sind die Dienste vorübergehend auf die Backup-Domain `radar-backup.meteogate.eu` umgezogen (API `https://radar-backup.meteogate.eu/api`, MQTT über diese Domain, S3 `https://object-store.os-api.cci1.ecmwf.int/openradar-24h-backup`). Das erklärt den leeren CloudFerro-Haupt-Bucket bei unserem Abruf.
- [F] Regulär gelten: MeteoGate-API `https://api.meteogate.eu/eu-eumetnet-weather-radar` und S3 `openradar-24h` bei CloudFerro (`s3.waw3-1.cloudferro.com`); beide Buckets nutzen dasselbe Pfadschema.
- [F] Die Doku nennt kein Ende der Störung und keinen Zeitpunkt der Rückkehr. [?] Wann der Haupt-Bucket wieder befüllt wird, ist offen.
- [A] Betriebsstrategie: beide Buckets in fester Reihenfolge versuchen (zuerst der zuletzt erfolgreiche), bei 404/403/5xx den anderen nehmen; Endpunkte konfigurierbar halten.

**2. Erlaubte Abrufrate**
- [F] MeteoGate-API: anonym nur „low query limits“, für Dauerbetrieb nicht empfohlen; mit kostenlosem API-Key höheres Limit (Developer Portal); Header `x-ratelimit-remaining`. Das Gateway begrenzt Anfragen und Raten, ohne Zahlen in der Doku.
- [F] Terms of Use/Data Governance Policy: „fair use“, „avoid excessive or abusive automated queries“; für große Bulk-Downloads den Datenlieferanten kontaktieren. Nur 24-h-Cache; Archiv „TBD“.
- [F] Für die S3-Buckets nennt die Doku keine Zahl. [?] Konkrete Limits (S3 und API mit/ohne Key) sind unveröffentlicht.
- [A] Ein Abruf je 5-min-Slot (1 Datei, ca. 4 MB, eine Anfrage, bei 404 höchstens wenige Wiederholungen) ist moderat; vor Produktivbetrieb API-Key anlegen (Developer Portal, nicht ausgeführt) oder per MQTT-Meldung statt Polling.

**3. Attribution**
- [F] Lizenz CC BY 4.0, Rechteinhaber der Komposite ist EUMETNET; Datei-Metadaten: `license` CC BY 4.0, `publisher_name` EUMETNET, `creator_name` Meteo France (CIRRUS). Doku: „Cite the data source where required by the license“ und Änderungen (Verarbeitung, Umformatierung) kenntlich machen.
- [F] Einen festen Wortlaut gibt die offizielle Doku nicht vor. [?] Konkreter Pflichttext offen.
- [A] Vorschlag (CC-BY-konform): „Radardaten Europa: EUMETNET OPERA (CIRRUS), CC BY 4.0, Quelle: MeteoGate; umprojiziert und eingefärbt.“ Link auf Lizenz und Quelle in den Einstellungen/Rechtlichem; DWD-Vermerk für Deutschland bleibt.

**4. Was LibreWXR macht (nur gelesen)**
- [F] Quelle: ausschließlich die öffentlichen S3-Buckets (CIRRUS DBZH, ODIM HDF5), anonym, ohne Schlüssel, ohne MeteoGate-API. Reihenfolge: CloudFerro `openradar-24h` primär, ECMWF `openradar-24h-backup` als Ersatz; beide konfigurierbar. Gleiches Pfadschema wie bei uns gemessen.
- [F] Takt: 5 min. Dateien erscheinen laut README mit ca. 5 bis 10 min Verzug (unsere Messung: ca. 4,5 min). Pro Zyklus bis zu 3 ältere Slots als Rückfall bei 404/403; ein gesunder Zyklus kostet keine Zusatzanfragen; es bleibt beim zuletzt erfolgreichen Bucket. Schon im Speicher vorhandene Frames werden nicht erneut geladen. Wechsel des Buckets wird nur beim Wechsel geloggt.
- [F] Auswertung: `gain=1, offset=0` (dBZ), nodata und undetect als „kein Wert“; Abdeckungsmaske ca. 300 km um die Radare; OPERA nur als Lückenfüller für Pixel mit echtem Niederschlag. Das deckt sich mit unserer Messung.
- [F] Der Betreiber hat dieselbe Backup-Logik wegen der Umleitung eingebaut; er verweist ebenfalls auf die „ORD Backup“-Notiz. Eine Attributionsformel steht in deren README (Verweis auf EUMETNET OPERA und MeteoGate), kein Pflichttext von EUMETNET.
- [A] Was wir lernen: (a) zwei Buckets mit Fallback, (b) Rückfall auf bis zu drei ältere Slots, (c) nur anonymer S3-Zugriff reicht in der Praxis. Nichts davon wurde kopiert; der Code wird nicht übernommen (AGPL).

**Danach noch unklar**
- Rückkehr des CloudFerro-Haupt-Buckets (Zeitpunkt, ob Backup dauerhaft bleibt).
- Konkrete Rate-Limits (S3 und MeteoGate, anonym/mit Key); MeteoGate-Terms-of-Use-Volltext nicht gelesen.
- Offizieller Pflichttext der Attribution.
- NIMBUS/RATE und `.tiff` weiterhin nicht geöffnet.

## 9. MeteoGate-Nutzungsbedingungen und Data Governance Policy (17. November 2026)

Quellen (nur gelesen, keine Mail): MeteoGate-Doku `https://eumetnet.github.io/meteogate-documentation/2-discovering-and-accessing-data/` und `.../references/`; Data Governance Policy (Word-Datei) `https://github.com/EUMETNET/meteogate-documentation/raw/main/files/Data_governance_policy.docx`; EUMETNET-Website-Bedingungen `https://www.eumetnet.eu/legal-information-2/`. Ein eigenständiges „Terms of Use“-Dokument ist nirgends verlinkt: `meteogate.eu/terms-of-use/` liefert 404, die Referenzseite listet nur Privacy Policy, Data Governance Policy und Participation Management Policy. Die Doku verweist für „Terms of Use“ und „Fair Use“ auf die Referenzseite, faktisch ist die Data Governance Policy der maßgebliche Text.

**[F] Belegt**
- Anonymer Zugriff: Policy, Zugangsstufe „Unauthenticated access – Open access to a minimum of WMO Core Data ..., and EU High Value Datasets (HVD) for anonymous users.“ Doku: MeteoGate „is open to anonymous users and does not require registering“.
- Lizenz: Policy: HVD „shall be made available under the conditions of Creative Commons BY4.0 (CC-BY-4.0) license, or any equivalent which is not more restrictive.“ Nutzer müssen Daten „within the terms of the licenses as specified in the metadata“ nutzen (Doku). Die Metadaten der CIRRUS-Dateien nennen CC BY 4.0 (siehe Abschnitt 8). CC BY 4.0 erlaubt Weitergabe, Bearbeitung und kommerzielle Nutzung.
- Attribution: Policy: „Data Owners are responsible for specifying the need for attribution through their licenses.“ Doku: „Cite the data source where required by the license.“ und Änderungen kenntlich machen. Einen festen Wortlaut gibt es nicht.
- Fair Use: Policy: „Users are expected to use MeteoGate reasonably.“ und „accidental or deliberate heavy traffic from an IP address may result in disconnection.“ Doku: „Avoid excessive or abusive automated queries.“ Keine Zahlen, weder in Policy noch Doku.
- Registrierte Nutzer: höhere Servicequalität (Policy), können vom FEMDI-Koordinator kontaktiert werden. Bei kurzen Lastspitzen dürfen Nutzer/Datensätze priorisiert werden (anonym ist die niedrigste Stufe).
- Sanktion: Bei unsachgemäßer Nutzung von urheberrechtlich geschützten Daten „a warning, suspension, or ban from MeteoGate“ plus Maßnahmen des Dateneigners.
- Weitergabe/Caching: Das Verbot gilt nur für eingeschränkte Daten: „Do not redistribute restricted data without permission from the Data Owner.“ (Doku). Open Data (CC BY) ist davon nicht betroffen. Ein Cache-Verbot für offene Daten steht nirgends.
- Die „Allgemeinen Bedingungen“ der EUMETNET-Website (nur Private/Forschung/Bildung, Verbot automatisierter Extraktion, Zustimmung der Executive Director für Kommerzielles; Abschnitte 3.4, 3.5, 4.3) beziehen sich auf den „Content“ der Website eumetnet.eu. Gleichzeitig steht dort: MeteoGate „will neither affect ownership of shared data holdings nor impose additional conditions on data sharing“ und OPERA-Radardaten sind „openly available ... through MeteoGate“ unter CC BY 4.0.

**[A] Annahmen / Einschätzung (keine Rechtsberatung)**
- Automatisierter anonymer S3-Abruf des CIRRUS-Komposits, Umprojizieren, Einfärben, Weitergabe über die App (auch kommerziell, Caching auf unserem Server) ist nach CC BY 4.0 zulässig, sofern Attribution und Änderungshinweis stehen. Die Website-Bedingungen gelten dafür nicht.
- Pflichtangaben (konservativ): Urheber/Herausgeber EUMETNET (Erzeuger Météo-France, CIRRUS), Lizenz CC BY 4.0 mit Link, Quelle MeteoGate/OPERA, Hinweis „umprojiziert und eingefärbt“. Vorschlag aus Abschnitt 8 bleibt passend; sichtbar in der Karte (Kurzform) und im Rechtlichen (Volltext). Keine Aussage, dass EUMETNET die Verarbeitung billigt.
- Fair Use: Ein Abruf je 5-min-Slot durch einen einzigen Server (kein Abruf pro Endnutzer) ist unbedenklich. Endnutzer laden nur von unserem Backend, nie direkt von S3.
- Haftung: Daten „as is“; in der App Hinweis, dass Radar keine amtliche Warnung ist (ohnehin vorhanden).

**[?] Offen**
- Konkrete Zahlenlimits (S3/API) sind unveröffentlicht; die S3-Buckets nennen keine Nutzungsbedingungen, nur die Policy.
- Ob das Haupt-S3 oder nur das Backup „offiziell“ für Dauerbetrieb gedacht ist (siehe Abschnitt 8).
- Ob EUMETNET einen verbindlichen Attributionstext oder Logo-Vorgaben hat: nur per Anfrage klärbar (nicht gesendet).
- Policy liegt als .docx vor, Versionsstand/Datum nicht ersichtlich; vor Livegang erneut prüfen. Rechtsprüfung durch Jurist nicht erfolgt.
