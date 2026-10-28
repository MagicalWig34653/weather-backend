# Team und Aufgabenübergabe

Stand: 28. Oktober 2026. Diese Regeln setzen verbindliche Nutzerentscheidungen um. Die Forschung liefert Empfehlungen, keine allgemeine Qualitäts- oder Kostengarantie.

## Kleine Hierarchie

| Rolle | Verantwortung | Grenze |
|---|---|---|
| Hauptagent | Anforderungen klären, Prioritäten und Abnahme mit dem Nutzer abstimmen, Ergebnisse berichten | Ausschließlich koordinieren; keine eigene Recherche, Implementierung, Dateiänderung, Builds, Tests oder Veröffentlichung |
| Technischer Lead | Aufgaben zerlegen, neue ausführende Agents starten, Dateibesitz und Abhängigkeiten koordinieren, Berichte abgleichen | Ebenfalls ausschließlich koordinieren; technische Ausführung und Integration delegieren |
| Ausführender Agent | Einen klar begrenzten Auftrag bearbeiten, passende Prüfungen ausführen und eine belegte Übergabe liefern | Nur zugewiesene Dateien und Ressourcen verändern; keine eigenmächtige Scope-Erweiterung |

Daten, Oberfläche, QA, Signing, Review, Integration und Abschluss sind mögliche Aufgabenrollen, keine dauerhaft beschäftigten Teams. Ein ausführender Agent muss nicht wiederum einen Agent starten. Eine weitere Ebene ist nur für einen begründeten getrennten Auftrag sinnvoll und mit dem Lead abzustimmen.

## Frischer Agent je Ergebnisaufgabe

Jede neue abgegrenzte Aufgabe erhält einen neuen Agent. Eine Aufgabe bezeichnet ein zusammenhängendes überprüfbares Ergebnis, etwa eine Zeitformatkorrektur mit Regressionstest, nicht jeden Toolaufruf. Rückfragen und Präzisierungen zu einem noch laufenden Auftrag bleiben bei seinem Verantwortlichen. Nach Abschluss darf derselbe Agent nicht für einen anderen Auftrag wiederverwendet werden.

Ein Briefing nennt mindestens:

- Ziel, Abnahmekriterien und ausdrückliche Nicht-Ziele.
- Relevante Repo-Dokumente und bestätigte Befunde; nur benötigten Kontext übergeben.
- Exklusiv beschreibbare Dateien oder Verzeichnisse sowie verbotene Änderungen.
- Abhängigkeiten, benötigte Werkzeuge und zuständigen Build-/Simulator-Verantwortlichen.
- Erwartete Prüfungen, Übergabedokument und Grenzen für Commit, Push oder externe Änderungen.

Keine vollständigen Chatverläufe oder Rohlogs zur Standardübergabe machen. Aktuelle Nutzerentscheidungen müssen in der versionierten Dokumentation stehen, bevor ein frischer Agent darauf angewiesen ist.

## Parallelität und Kosten

Zunächst höchstens drei produktive ausführende Agents gleichzeitig einplanen. Unabhängige Aufgaben sollen parallel laufen; die Zahl kann bei belegbar unabhängiger Zusatzarbeit bewusst angepasst werden. Koordinatoren zählen nicht als produktive Worker, verursachen aber ebenfalls Kosten. Keine künstlichen Aufgaben zum Auslasten eines Teams erzeugen.

Im gemeinsamen Checkout erhält jede veränderliche Datei genau einen aktiven Besitzer. Projektgenerator, Build, Simulator und Signing-Vorgänge haben jeweils einen ausdrücklich benannten Verantwortlichen. Dieser entscheidet, wann gemeinsam genutzte Ressourcen frei sind. Abhängige Änderungen und Prüfungen sequenziell ausführen; nicht während eines Builds dieselben Quellen oder Projektdateien verändern. Für größere überlappende Änderungen können eigene Worktrees mit anschließend zugewiesener Integration sinnvoll sein.

Zuerst vorhandene Befunde lesen und gezielt suchen. Keine identischen Scans, Netzabrufe oder Tests mehrfach starten, solange keine neue Änderung, kein Fehler oder ungeklärter Befund dies rechtfertigt. Zusätzliche Infrastruktur oder kostenpflichtige Dienste brauchen einen entsprechenden Nutzerauftrag.

## Übergabe und fortsetzbare Sessions

Das Repo ist Source of Truth; Sessions und Agents sind wegwerfbar. Eine neue Session muss aus `AGENTS.md`, `docs/status.md`, `docs/decisions.md` und den verlinkten Befunden weiterarbeiten können. Kein notwendiger Stand darf nur im Agent-Gedächtnis, Chat, einem laufenden Prozess oder einer Notiz außerhalb des Repos existieren.

Relevante Entscheidungen, Änderungen, Quellen, Prüfergebnisse, offene Fragen und nächste Schritte fortlaufend im Repo festhalten. Dafür vorhandene Dokumente nutzen. Ein Worker schreibt nur in sein zugewiesenes Übergabedokument; Änderungen an gemeinsamem Status oder Entscheidungen übernimmt der dafür benannte Dokumentations-/Integrations-Agent. Der Lead muss diese dauerhafte Übergabe sicherstellen, ohne selbst Dateien zu ändern.

`docs/status.md` führt bei paralleler Arbeit knapp Ergebnisaufgaben, Dateibesitzer, Abhängigkeiten und Prüfverantwortliche. Die Übergabe nennt geänderte Dateien, tatsächlich ausgeführte Prüfungen samt Ergebnis, nicht ausgeführte Prüfungen, bekannte Grenzen und den konkreten nächsten Schritt. Git liefert die Historie; keine Sammlung vollständiger Sessionprotokolle anlegen.

Integration und risikobezogenes unabhängiges Review werden ebenfalls an ausführende Agents vergeben. Ein Abschluss-Agent aktualisiert den konsistenten Stand und führt autorisierte Commits/Pushes erst aus, wenn alle betroffenen schreibenden Agents fertig sind und Reviewbefunde geklärt wurden. „Build erfolgreich“, „Bundle-ID registriert“ und „in TestFlight verfügbar“ sind getrennte, jeweils zu belegende Ergebnisse.

## Private Rechnerkonfiguration

Absolute lokale Pfade gehören ausschließlich in die ignorierte `LOCAL_WORKSPACE.md`. Die öffentliche Vorlage enthält nur Platzhalter; GitHub-Verweise bleiben versioniert. Diese optionale Rechnerzuordnung ist die Ausnahme zur versionierten Übergabe, keine Ablage für Produktentscheidungen oder Arbeitsfortschritt. Keine Pfade, Tokens, Signing-Dateien oder Nutzerstandorte in öffentliche Dokumente, Rohlogs, Commits oder Issues übernehmen.

## Grundlage

[Recherche im Apple-Repo mit offiziellen Quellen und Abwägungen](https://github.com/MagicalWig34653/weather-apple/blob/main/docs/research/agent-orchestration.md).
