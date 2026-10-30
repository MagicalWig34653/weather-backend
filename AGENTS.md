# Arbeitsanweisungen

## Zuerst lesen

0. `docs/status.md`: Arbeitsstand, Prüfungen und nächste Schritte.
1. `docs/decisions.md`: aktueller Umfang, Reihenfolge, vorläufige Kennungen.
2. `docs/concept-v2.md`: detailliertes ursprüngliches Konzept.
3. `README.md`: aktueller Repository-Status.
4. `docs/team.md`: Rollen, Dateibesitz, Parallelität und Aufgabenübergabe.
5. Falls vorhanden `LOCAL_WORKSPACE.md`: private lokale Zuordnung zum Schwesterrepository. Vorlage: `LOCAL_WORKSPACE.example.md`. Die lokale Datei niemals committen oder ihre Pfade in öffentliche Dateien übernehmen. Vor Arbeit im Schwesterrepo dessen Anweisungen, Status und Git-Remote prüfen.

## Verbindlicher Entwicklungsprozess

- Möglichst kostensparsam arbeiten: zuerst vorhandene Dokumentation lesen, gezielt suchen, Aufgaben begrenzen und unnötige Wiederholungen, Vollscans oder parallele Doppelarbeit vermeiden. Keine kostenpflichtigen Dienste oder zusätzliche Infrastruktur ohne ausdrücklichen Auftrag einführen.
- Agents sind PFLICHT: Hauptagent und technischer Lead koordinieren ausschließlich. Recherche, Implementierung, Dateiänderungen, Builds, Tests, Integration und Veröffentlichung erledigen ausführende Agents. Für jede neue abgegrenzte Ergebnisaufgabe einen frischen Agent starten; abgeschlossene Agents nicht für andere Aufgaben wiederverwenden. Präzisierungen innerhalb eines laufenden Auftrags sind erlaubt. Ausführende Agents müssen nicht rekursiv weitere Agents starten.
- Unabhängige Aufgaben parallel vergeben, zunächst höchstens drei produktive Worker. Klare Dateizuständigkeiten und genau einen aktiven Verantwortlichen für gemeinsam genutzte Build-/Simulator-Ressourcen festlegen. Keine parallelen Änderungen derselben Dateien und keine Doppelprüfungen ohne konkreten Anlass.
- Der verbindliche Ablauf für Hierarchie, Briefing, Abnahme und dauerhafte Übergabe steht in `docs/team.md`. Falls die Umgebung keine Agents bereitstellt, Einschränkung dokumentieren und mit dem Nutzer klären, statt die Vorgaben stillschweigend zu umgehen.
- Sessions müssen wegwerfbar sein. Die Fortsetzung darf weder Chatverlauf noch Agent-Gedächtnis, Notizen außerhalb des Repos oder laufende Prozesse voraussetzen.
- Das Repo ist die Source of Truth. ALLE relevanten Nutzerentscheidungen, Planänderungen, Untersuchungsergebnisse samt Quellen, Änderungen, Prüfergebnisse, offenen Fragen und nächsten Schritte fortlaufend im Repo dokumentieren. Nicht erst am Sessionende nachtragen.
- Vor Arbeitsbeginn `docs/status.md`, `docs/decisions.md` und den Git-Status prüfen. Vor Abschluss oder Übergabe den Status und gegebenenfalls die Entscheidungen aktualisieren. Nicht ausgeführte Prüfungen ausdrücklich benennen.
- Dokumentation knapp und nachvollziehbar halten. Keine Chattranskripte, Rohlogs, Geheimnisse oder personenbezogenen Daten archivieren. Größere Untersuchungen bei Bedarf unter `docs/research/` ablegen und verlinken. Git bildet die Historie; keine ständig neuen Session-Protokolle erzeugen.

## Auftrag und Grenzen

Zentraler optionaler Pushdienst mit Swift/Vapor, MariaDB und Docker Swarm. Kein PHP trotz des lokalen PhpstormProjects-Pfads. Backend-Implementierung folgt erst nach einer nutzbaren App. Keine Benutzerkonten, kein Dashboard und kein Self-Hosting-Produkt.

- Entwicklung ist nach den am 28. Oktober 2026 beantworteten Einstiegsfragen freigegeben. Nach `docs/plan.md` arbeiten: Datenvalidierung und App zuerst; Backend-Implementierung erst nach nutzbarer App. Offene zentrale Architekturentscheidungen weiterhin besprechen.
- Zentrale offene Architekturentscheidungen besprechen, statt sie stillschweigend festzulegen.
- Bestätigte Fakten, Annahmen und zu testende Hypothesen unterscheiden. DWD-Produkte, Schnittstellen, Lizenzen und Plattformverhalten vor darauf gestützten Implementierungsentscheidungen anhand aktueller Primärquellen überprüfen.
- Deutsch mit dem Nutzer kommunizieren; Codebezeichner später auf Englisch. Dokumentation im bestehenden Stil halten.
- Keine Geheimnisse, Signing-Dateien, APNs-Schlüssel, Tokens, echten Nutzerstandorte oder lokalen Zugangsdaten committen.
- Datenschutz als Produktanforderung behandeln. Keine Standortverläufe oder identifizierende Debuglogs einführen.
- Das Backend-Repo enthält den Radar-Cache (Swift: `Sources/`, `Tests/`, `migrations/`, `deploy/swarm/`); Build-/Test-Befehle stehen im `README.md`. Nur tatsächlich ausgeführte Prüfungen als erfolgreich melden; Prüfungen der Apple-App gelten nicht als Backend-Prüfungen. Öffentliches Repo: keine Geheimnisse, echten Domains, IPs, Hostnamen oder Nutzerpfade.
- Keine unaufgeforderten Infrastrukturkomponenten oder plattformübergreifenden Abstraktionen einführen.
- Änderungen an Produktumfang und Entscheidungen in `docs/decisions.md` nachvollziehbar festhalten. Das ursprüngliche Konzept nicht stillschweigend überschreiben.
- App-Name, Bundle-ID und Team-ID sind vorläufig; keine Signing-/Store-Ressourcen ohne den entsprechenden Arbeitsauftrag anlegen.
