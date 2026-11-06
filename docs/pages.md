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

## Landingpage: Recherche und Quellen (6.11.2026)

Gestaltungsleitlinien (Typografie, Token-Farbsystem, Abstände, Dark Mode, Reduced Motion) aus dem Design-Skill; Anregungen (nicht kopiert, kein Code übernommen) aus MIT-lizenzierten Vorlagen: sandoche/Mobile-app-landingpage-template (MIT), bohd4nx/app-landing (MIT), xu42/simple-app-landing-page-template (MIT); Lizenz der ersten beiden per GitHub-API geprüft. Allgemeine Hinweise (Hero mit Gerätemockup, stärkster Screenshot zuerst, Alt-Texte) aus Websuche; die Quellen sind teils schwach, daher nur als Anregung. Umsetzung ist Eigenbau: Systemschrift, CSS-Geräterahmen, keine Fremdschriften oder Bibliotheken, daher keine Namensnennung nötig. Prüfung: Playwright 360/768/1280/1920 px, hell/dunkel, DE/EN, axe-core ohne Verstöße, kein horizontaler Überlauf. Lighthouse nicht ausgeführt.
