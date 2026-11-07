# Warnungen: Ereigniscodes (W1.1, 7. November 2026)

Zweck: Zuordnung `eventCode II` zu `kind` für `WarnEventMap` (`Sources/RadarCore/WarnEventMap.swift`). Fail-closed: Was hier nicht steht, wird nicht gespeichert, nur gezählt.

## Quellen

- **Primär (belegt):** DWD "Warnungen (WW/WU)", `warning_codes.pdf` (Stand 01.02.2024, Seite am 7.11.2026 abgerufen über die DWD-Opendata-Hilfeseite, Abschnitt Warnungen CAP): Tabellen WW/WU, Vorabinformationen Unwetter (WP), UV/Hitze, Küste, Hochsee, Binnensee. Spalten `ii`, `event`, Stufe, Bemerkung.
- **Echte Meldungen (belegt):** Stichprobe des Feeds `COMMUNEUNION_DWD_STAT` (DE) vom 5. bis 7.11.2026 (40 Archivdateien, 143 Meldungen) und die aktuelle `LATEST`-Datei (DE und EN). Beobachtet: `II` 22 `FROST` (GROUP `FROST`, Minor), `II` 84 `GLÄTTE` (GROUP `SLIPPERINESS`, Minor), `II` 59 `NEBEL` (GROUP `FOG`, Minor). Alle anderen Codes kamen in der Stichprobe nicht vor (Novemberlage).
- Die englische Datei trägt englische Eventnamen (`frost`), aber denselben `II`.

## Zuordnung (Nutzerentscheidung 7.11.2026)

Gruppen: Gewitter, Böen/Sturm/Orkan, Starkregen/Dauerregen, Schneefall/Schneeverwehung, Tauwetter = `severe_weather`; Frost/Strenger Frost = `frost`; Glätte/Glatteis = `ice`; Hitze, UV, Nebel = ignoriert.

| II | event (DE, laut Dokument) | Stufe lt. Dokument | kind | Beleg |
|---|---|---|---|---|
| 22 | FROST | 1 | frost | Dokument + echte Meldung |
| 82 | STRENGER FROST | 2 | frost | Dokument |
| 84 | GLÄTTE | 1 | ice | Dokument + echte Meldung |
| 85 | GLATTEIS | 3 | ice | Dokument |
| 86 | EXTREMES GLATTEIS | 4 | ice | Dokument |
| 87 | MARKANTE GLÄTTE | 2 | ice | Dokument |
| 31 | GEWITTER | 1 | severe_weather | Dokument |
| 33, 34, 36, 38 | STARKES GEWITTER | 2 | severe_weather | Dokument |
| 40 | SCHWERES GEWITTER mit ORKANBÖEN | 3 | severe_weather | Dokument |
| 41 | SCHWERES GEWITTER mit EXTREMEN ORKANBÖEN | 4 | severe_weather | Dokument |
| 42 | SCHWERES GEWITTER mit HEFTIGEM STARKREGEN | 3 | severe_weather | Dokument |
| 44 | SCHWERES GEWITTER mit ORKANBÖEN und HEFTIGEM STARKREGEN | 3 | severe_weather | Dokument |
| 45 | SCHWERES GEWITTER mit EXTREMEN ORKANBÖEN und HEFTIGEM STARKREGEN | 4 | severe_weather | Dokument |
| 46 | SCHWERES GEWITTER mit HEFTIGEM STARKREGEN und HAGEL | 3 | severe_weather | Dokument |
| 48 | SCHWERES GEWITTER mit ORKANBÖEN, HEFTIGEM STARKREGEN und HAGEL | 3 | severe_weather | Dokument |
| 49 | SCHWERES GEWITTER mit EXTREMEN ORKANBÖEN, HEFTIGEM STARKREGEN und HAGEL | 4 | severe_weather | Dokument |
| 90 | GEWITTER | 1 | severe_weather | Dokument ("nur im Standardprodukt") |
| 91 | STARKES GEWITTER | 2 | severe_weather | Dokument ("nur im Standardprodukt") |
| 92 | SCHWERES GEWITTER | 3 | severe_weather | Dokument ("nur im Standardprodukt") |
| 93 | EXTREMES GEWITTER | 4 | severe_weather | Dokument ("nur im Standardprodukt") |
| 95 | SCHWERES GEWITTER mit EXTREM HEFTIGEM STARKREGEN und HAGEL | 4 | severe_weather | Dokument |
| 96 | EXTREMES GEWITTER mit ORKANBÖEN, EXTREM HEFTIGEM STARKREGEN und HAGEL | 4 | severe_weather | Dokument |
| 51 | WINDBÖEN | 1 | severe_weather | Dokument |
| 52 | STURMBÖEN | 2 | severe_weather | Dokument |
| 53 | SCHWERE STURMBÖEN | 2 | severe_weather | Dokument |
| 54 | ORKANARTIGE BÖEN | 3 | severe_weather | Dokument |
| 55 | ORKANBÖEN | 3 | severe_weather | Dokument |
| 56 | EXTREME ORKANBÖEN | 4 | severe_weather | Dokument |
| 61 | STARKREGEN | 2 | severe_weather | Dokument |
| 62 | HEFTIGER STARKREGEN | 3 | severe_weather | Dokument |
| 63 | DAUERREGEN | 2 | severe_weather | Dokument |
| 64 | ERGIEBIGER DAUERREGEN | 3 | severe_weather | Dokument |
| 65 | EXTREM ERGIEBIGER DAUERREGEN | 4 | severe_weather | Dokument |
| 66 | EXTREM HEFTIGER STARKREGEN | 4 | severe_weather | Dokument |
| 70 | LEICHTER SCHNEEFALL | 1 | severe_weather | Dokument |
| 71 | SCHNEEFALL | 2 | severe_weather | Dokument |
| 72 | STARKER SCHNEEFALL | 3 | severe_weather | Dokument |
| 73 | EXTREM STARKER SCHNEEFALL | 4 | severe_weather | Dokument |
| 74 | SCHNEEVERWEHUNG | 2 | severe_weather | Dokument |
| 75 | STARKE SCHNEEVERWEHUNG | 3 | severe_weather | Dokument |
| 76 | EXTREM STARKE SCHNEEVERWEHUNG | 4 | severe_weather | Dokument |
| 88 | TAUWETTER | 2 | severe_weather | Dokument |
| 89 | STARKES TAUWETTER | 3 | severe_weather | Dokument |

`WarnEventMap.rows` enthält 46 Codes (Test `documentedRowCount`). Bei 33/34/36/38 teilen sich vier Codes denselben Eventnamen.

## Ignoriert (nicht gespeichert)

| II | event | Grund |
|---|---|---|
| 59 | NEBEL | Nutzerentscheidung; in echten Meldungen beobachtet (GROUP `FOG`) |
| 246, 247, 248 | UV-INDEX, HITZE, EXTREME HITZE | Nutzerentscheidung |
| 98, 99 | TEST-WARNUNG, TEST-UNWETTERWARNUNG | Test |
| 79 | LEITERSEILSCHWINGUNGEN | laut Dokument nicht im CAP auf Opendata |
| 11, 12, 13 | BÖEN, WIND, STURM (Küste) | nicht im Umfang v1 |
| 14, 15, 16 | Starkwind, Sturm, schwerer Sturm (Hochsee) | nicht im Umfang v1 |
| 57, 58 | STARKWIND, STURM (Binnensee) | nicht im Umfang v1 |
| 40, 55, 65, 75, 85, 89, 99 | VORABINFORMATION ... (WP) | **Kollision:** gleiche `II` wie die Warnungen 40/55/65/75/85/89 |

## Offen und konservativ behandelt (ungeprüft)

- **Kollision Vorabinformation:** Die Vorabinformationen (WP) nutzen dieselben `II` wie sechs Warncodes und unterscheiden sich nur im Eventnamen. `WarnEventMap` nimmt für diese sechs Codes nur den exakten deutschen Warn-Eventnamen an; alles andere wird ignoriert. Folge: Die englische Datei hat englische Namen, ihre Meldungen mit diesen sechs Codes werden ignoriert (die App zeigt dann den deutschen Text mit `lang: de`). Ob die englischen Namen der Vorabinformation anders lauten, ist **nicht geprüft** (in der Stichprobe nicht aufgetreten).
- Die Stufenspalte des Dokuments ist nicht maßgeblich; maßgeblich ist `severity` der Meldung (CAP `Minor`..`Extreme`). An echten Meldungen geprüft ist nur `Minor` (Stufe 1) bei 22, 59, 84; `Moderate`/`Severe`/`Extreme` stammen aus dem Profil.
- Der Stand des Dokuments ist 01.02.2024 (WW/WU) bzw. 15.05.2020 (übrige Tabellen); neue Codes seither sind nicht ausgeschlossen. Sie werden ignoriert und über `ignoredEvents` gezählt, nicht geraten.
- Codes 90 bis 93 gelten laut Dokument nur im Standardprodukt; im Premium-Feed nicht beobachtet.
- Hinweis zum Feed: Die `LATEST`-Datei kann ein leeres ZIP sein (keine Differenz); der Abruf behandelt das als "keine Dateien".
