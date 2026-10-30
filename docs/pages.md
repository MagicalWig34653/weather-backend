# GitHub-Pages-Dokumentation

Öffentliche Seite: `https://magicalwig34653.github.io/weather-backend/` (Projekt-Pages, alle Links relativ).

## Aufbau

- Generator `docs-site/build.mjs` (Node, einzige Abhängigkeit `marked`), Stil `docs-site/style.css`; Stack und Look wie die Seite des App-Repos und des Projekts todo.
- Kuratierte Seiten in `docs-site/content/*.md`: Start, Architektur, Installation, Betrieb, API, Entwicklung, Roadmap.
- Eingebunden wird der Abschnitt „Entwicklung und Tests“ aus `README.md` (Seite Entwicklung). Links auf nicht veröffentlichte `docs/`-Dateien zeigen auf GitHub.
- Nicht veröffentlicht: Status, Arbeitsprozess, Konzept. Die Seiten fassen `docs/decisions.md` zusammen; bei Änderungen an Skripten (`deploy/swarm/*.sh`, `deploy/swarm/swarm-deploy.sh`), `.env.example`, `stack.yaml` oder dem HTTP-Vertrag müssen `installation`, `betrieb` und `api` mitgezogen werden (Optionen und Variablennamen gegen `setup.sh --help` und `update.sh --help` abgleichen).

## Lokaler Build

```sh
cd docs-site && npm ci && node build.mjs   # Ausgabe: docs-site/dist
```

`node_modules/` und `dist/` sind per `.gitignore` ausgeschlossen.

## Deployment

`.github/workflows/pages.yml` baut bei Push auf `main` (Pfade `docs-site/**`, `README.md`, Workflow) oder manuell und veröffentlicht mit `actions/deploy-pages`. Actions sind auf Commit-SHAs gepinnt, Berechtigungen minimal (`contents: read`, `pages: write`, `id-token: write`). Einmalig: Pages-Quelle „GitHub Actions“ (`gh api -X POST repos/MagicalWig34653/weather-backend/pages -f build_type=workflow`).

## Prüfungen vor Änderungen

Lokal bauen, interne Links prüfen, keine privaten Pfade, echten Domains, IPs, Hostnamen oder Tokens in `docs-site/` (Suche vor dem Commit).
