# Claude Code

Lies vor der Arbeit die gemeinsamen Repository-Anweisungen:

@AGENTS.md

Die aktuellen Produktentscheidungen stehen in `docs/decisions.md`, Plan und Arbeitsstand in `docs/plan.md` und `docs/status.md`.

Dieses Backend-Repo enthält seit dem 30. Oktober 2026 den Radar-Cache (Stufe 1, Swift/Vapor, siehe `README.md`); der Pushdienst folgt später. Env-Dateien heißen immer `.env`; Vorlage für Deploy-Skripte und CI ist das Referenzprojekt todo (Struktur wie dort).

Verbindlich: Hauptagent und technischer Lead koordinieren ausschließlich; jede neue Ergebnisaufgabe erhält einen frischen ausführenden Agent. Unabhängige Aufgaben mit getrenntem Dateibesitz parallel bearbeiten, zunächst höchstens drei produktive Worker. Der Ablauf steht in `docs/team.md`.

Möglichst kostensparsam arbeiten. Sessions müssen wegwerfbar sein; das Repo ist Source of Truth. Relevante Ergebnisse, Prüfungen und nächste Schritte gemäß `AGENTS.md` fortlaufend im zugewiesenen Repo-Dokument festhalten. Private lokale Pfade ausschließlich in der ignorierten `LOCAL_WORKSPACE.md` belassen.

<!-- todolino:begin -->
## Todolino

Dieses Projekt wird in Todolino geplant (Projekt-ID in `.todolino.json`). Das Board laufend nutzen, nicht nur einmal am Ende:
- Start: `session_start` (Skill `todolino`) oder `get_sync_status`, `get_command_center`, `list_open_questions`, `list_pending_reviews`; ist das Board veraltet, zuerst `sync_project`.
- Vor der Arbeit: passende Aufgabe suchen oder mit `create_task` anlegen (keine Duplikate), dann `claim_task`.
- Nach jedem abgeschlossenen Teilschritt und jedem Commit: `post_progress`.
- Entscheidungen des Nutzers als `ask_question` an der Aufgabe stellen statt nur im Chat zu fragen.
- Fertig: `request_review` NUR wenn der Nutzer etwas ansehen oder entscheiden muss (sichtbares Ergebnis, Risiko, Rollout). Reine Update-Infos (Commit, Tests grün, interne Änderung) gehören in `post_progress`, nicht in ein Review. Eigene Arbeit nie selbst auf erledigt setzen. Ende: `record_sync`.
- Texte am Board kurz und in Stichpunkten: Überschrift = Aufgabentitel; Review: ein Satz Ergebnis + höchstens 4 Stichpunkte (neu, geprüft, ansehen, offen); Frage: 1 bis 2 Zeilen + 2 bis 4 Optionen, Empfehlung zuerst; Fortschritt: 1 bis 2 Sätze.
- Gestartete Agenten bekommen die Aufgaben-ID im Prompt und melden `post_progress` selbst; die Hauptsession stellt das Review.
<!-- todolino:end -->
