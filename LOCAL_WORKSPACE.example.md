# Vorlage für lokale Repository-Zuordnung

Diese Datei nach `LOCAL_WORKSPACE.md` kopieren und ausschließlich dort die absoluten Pfade auf diesem Rechner eintragen. `LOCAL_WORKSPACE.md` wird über `.gitignore` ausgeschlossen und darf nicht mit `git add -f` versioniert werden.

- Apple-Repository: `<lokaler absoluter Pfad zum Apple-Repository>`
- Backend-Repository: `<lokaler absoluter Pfad zum Backend-Repository>`

Die öffentlichen GitHub-Adressen stehen in `docs/status.md`. Lokale Pfade sind optionale Rechnerkonfiguration. Fehlt die lokale Datei, das Schwesterrepo über die dokumentierte GitHub-Adresse beziehen oder seinen lokalen Pfad erfragen; keine ungezielte Suche über den Rechner.

Vor repoübergreifender Arbeit im Ziel die Arbeitsanweisungen, den Status und das Git-Remote prüfen. Keine privaten Pfade in öffentliche Dokumentation, Issues, Logs oder Commits übernehmen. Fachliche Entscheidungen und Arbeitsstände gehören weiterhin in die versionierte Dokumentation.
