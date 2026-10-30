# Claude Code

Lies vor der Arbeit die gemeinsamen Repository-Anweisungen:

@AGENTS.md

Die aktuellen Produktentscheidungen stehen in `docs/decisions.md`, Plan und Arbeitsstand in `docs/plan.md` und `docs/status.md`.

Dieses Backend-Repo enthält seit dem 30. Oktober 2026 den Radar-Cache (Stufe 1, Swift/Vapor, siehe `README.md`); der Pushdienst folgt später. Env-Dateien heißen immer `.env`; Vorlage für Deploy-Skripte und CI ist das Referenzprojekt todo (Struktur wie dort).

Verbindlich: Hauptagent und technischer Lead koordinieren ausschließlich; jede neue Ergebnisaufgabe erhält einen frischen ausführenden Agent. Unabhängige Aufgaben mit getrenntem Dateibesitz parallel bearbeiten, zunächst höchstens drei produktive Worker. Der Ablauf steht in `docs/team.md`.

Möglichst kostensparsam arbeiten. Sessions müssen wegwerfbar sein; das Repo ist Source of Truth. Relevante Ergebnisse, Prüfungen und nächste Schritte gemäß `AGENTS.md` fortlaufend im zugewiesenen Repo-Dokument festhalten. Private lokale Pfade ausschließlich in der ignorierten `LOCAL_WORKSPACE.md` belassen.
